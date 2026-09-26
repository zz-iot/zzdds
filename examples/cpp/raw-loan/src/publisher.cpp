/*
 * cpp/raw-loan -- publisher. Direct C++ port of zig/raw-loan/publisher.zig;
 * see docs/design/raw-loan-reference-app.md at the repo root for the full
 * spec. Bypasses TypeSupport marshaling entirely: every published sample
 * goes through loan_raw() -> serialize directly into it (counting pass to
 * size, fixed-mode pass to write) -> publish_loan_raw(), instead of the
 * generated typed DataWriter::write() a normal example would use. Also
 * demonstrates the cancel path -- loan_raw() then return_loan_raw() without
 * ever publishing.
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * writer for topic:", "Publisher: published (loan) sequence=", "Publisher:
 * cancelling loan for sequence=", "Publisher: done." Any failure path
 * prints a line starting "FAIL:" and exits nonzero.
 */
#include "loaned_ping.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#ifdef _WIN32
#include <windows.h>
static void sleep_ms(int ms) { Sleep((DWORD)ms); }
#else
#include <unistd.h>
static void sleep_ms(int ms) { usleep((useconds_t)ms * 1000); }
#endif

namespace {

constexpr int SAMPLE_COUNT = 5;
constexpr int CANCELLED_SEQ_NUM = -1;
constexpr int READER_READY_TIMEOUT_MS = 10000;
constexpr int DRAIN_TIMEOUT_MS = 15000;
constexpr int POLL_PERIOD_MS = 20;

struct PubState {
    std::atomic<bool> reader_ready{false};
    std::atomic<bool> ever_matched{false};
    std::atomic<int> matched_current_count{0};
};

class PubListener : public ::zzdds::DataWriterListenerExBase {
public:
    explicit PubListener(PubState *state) : state_(state) {}

    void on_publication_matched(std::shared_ptr<::DDS::DataWriter> /*writer*/,
                                 ::DDS::PublicationMatchedStatus status) override {
        state_->matched_current_count.store(status.current_count);
        if (status.current_count > 0) state_->ever_matched.store(true);
        std::printf("on_publication_matched() current_count=%d\n", status.current_count);
    }

    void on_reliable_reader_ready(::DDS::InstanceHandle_t /*reader_handle*/, bool is_ready) override {
        if (is_ready) state_->reader_ready.store(true);
        std::printf("on_reliable_reader_ready() is_ready=%s\n", is_ready ? "true" : "false");
    }

private:
    PubState *state_;
};

/* Loan a buffer sized for `value`, serialize directly into it via a
 * counting pass (to learn the size) then a fixed-mode pass (to write into
 * the real loaned buffer) -- true zero-copy, no intermediate malloc'd
 * buffer. Returns 0 and leaves the loan outstanding in cdr_payload on
 * success, or -1 on any failure. */
int loan_and_serialize(std::shared_ptr<::DDS::DataWriter> dw, const ::LoanedPing &value, DDS_OctetSeq &cdr_payload) {
    ZidlCdrWriter counting;
    zidl_cdr_writer_init_counting(&counting, ZIDL_XCDR1);
    if (zidl_cdr_write_encap(&counting) != 0) return -1;
    if (LoanedPing_serialize(&counting, &value) != 0) return -1;

    if (dw->loan_raw(static_cast<uint32_t>(counting.len), cdr_payload) != ::DDS::RETCODE_OK) return -1;

    ZidlCdrWriter fixed;
    zidl_cdr_writer_init_fixed(&fixed, cdr_payload._buffer, cdr_payload._maximum, ZIDL_XCDR1);
    if (zidl_cdr_write_encap(&fixed) != 0) {
        dw->return_loan_raw(cdr_payload);
        return -1;
    }
    if (LoanedPing_serialize(&fixed, &value) != 0) {
        dw->return_loan_raw(cdr_payload);
        return -1;
    }
    return 0;
}

int publish_loaned(std::shared_ptr<::DDS::DataWriter> dw, const ::LoanedPing &value) {
    DDS_OctetSeq cdr_payload{};
    if (loan_and_serialize(dw, value, cdr_payload) != 0) return -1;

    uint8_t hash_bytes[16];
    LoanedPing_compute_key_hash(&value, hash_bytes);
    ::DDS::OctetSeq key_hash(hash_bytes, hash_bytes + 16);

    if (dw->publish_loan_raw(cdr_payload, key_hash, ::DDS::HANDLE_NIL, ::DDS::WriteKind::ALIVE_WRITE_KIND) != ::DDS::RETCODE_OK) return -1;
    return 0;
}

int loan_and_cancel(std::shared_ptr<::DDS::DataWriter> dw, const ::LoanedPing &value) {
    DDS_OctetSeq cdr_payload{};
    if (loan_and_serialize(dw, value, cdr_payload) != 0) return -1;
    if (dw->return_loan_raw(cdr_payload) != ::DDS::RETCODE_OK) return -1;
    return 0;
}

uint32_t parse_domain(int argc, char **argv) {
    for (int i = 1; i < argc - 1; i++) {
        if (std::strcmp(argv[i], "-d") == 0 || std::strcmp(argv[i], "--domain") == 0) {
            return static_cast<uint32_t>(std::strtoul(argv[i + 1], nullptr, 10));
        }
    }
    return 0;
}

} // namespace

int main(int argc, char **argv) {
    uint32_t domain_id = parse_domain(argc, argv);

    auto factory = zzdds::create_factory();
    if (!factory) {
        std::fprintf(stderr, "FAIL: createFactory() failed\n");
        return 1;
    }

    auto dp = factory->create_participant(domain_id, ::DDS::DomainParticipantQos::default_value(), nullptr, 0);
    if (!dp) {
        std::fprintf(stderr, "FAIL: create_participant() failed on domain %u\n", domain_id);
        return 1;
    }
    auto dp_handle = dp->native_handle();

    if (LoanedPingTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto topic = dp->create_topic("LoanedPing", "LoanedPing", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    std::printf("Create topic: LoanedPing\n");

    auto pub = dp->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    if (!pub) {
        std::fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    auto dw_qos = ::DDS::DataWriterQos::default_value();
    dw_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    auto dw = pub->create_datawriter(topic, dw_qos, nullptr, 0);
    if (!dw) {
        std::fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    std::printf("Create writer for topic: LoanedPing\n");

    PubState state;
    auto listener = std::make_shared<PubListener>(&state);
    auto zdw = std::static_pointer_cast<::zzdds::DataWriterImpl>(dw);
    if (zdw->set_listener_ex(listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener_ex failed\n");
        return 1;
    }

    for (int waited_ms = 0; !state.reader_ready.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        sleep_ms(POLL_PERIOD_MS);
    }

    // -- Write-loan phase --
    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        ::LoanedPing sample;
        sample.seq_num = seq;
        if (publish_loaned(dw, sample) != 0) {
            std::fprintf(stderr, "FAIL: publish_loaned() failed at sequence=%d\n", seq);
            return 1;
        }
        std::printf("Publisher: published (loan) sequence=%d\n", seq);
    }

    // -- Cancel phase --
    {
        ::LoanedPing cancelled;
        cancelled.seq_num = CANCELLED_SEQ_NUM;
        if (loan_and_cancel(dw, cancelled) != 0) {
            std::fprintf(stderr, "FAIL: loan_and_cancel() failed\n");
            return 1;
        }
        std::printf("Publisher: cancelling loan for sequence=%d (never published)\n", CANCELLED_SEQ_NUM);
    }

    for (int waited_ms = 0;
         !(state.ever_matched.load() && state.matched_current_count.load() == 0);
         waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: subscriber did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        sleep_ms(POLL_PERIOD_MS);
    }

    if (pub->delete_datawriter(dw) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: delete_datawriter() did not return RETCODE_OK -- an outstanding loan leaked\n");
        return 1;
    }

    std::printf("Publisher: done.\n");
    return 0;
}
