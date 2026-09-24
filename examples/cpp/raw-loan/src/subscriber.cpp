/*
 * cpp/raw-loan -- subscriber. Direct C++ port of
 * zig/raw-loan/subscriber.zig; see docs/design/raw-loan-reference-app.md at
 * the repo root for the full spec. Bypasses TypeSupport marshaling
 * entirely: every sample is read via take_raw() in loan mode -> deserialize
 * straight out of the borrowed bytes -> return_loan_raw().
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * reader for topic:", "Subscriber: received (loan) sequence=",
 * "Subscriber: received all N samples in order." Any failure path prints
 * a line starting "FAIL:" and exits nonzero.
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
constexpr int RECEIVE_TIMEOUT_MS = 30000;
constexpr int POLL_PERIOD_MS = 20;

struct SubState {
    int expected_next = 0;
    std::atomic<bool> all_received{false};
};

class SubListener : public ::DDS::DataReaderListenerBase {
public:
    explicit SubListener(SubState *state) : state_(state) {}

    void on_data_available(std::shared_ptr<::DDS::DataReader> reader) override {
        for (;;) {
            DDS_OctetSeqSeq payloads{}; // _maximum == 0 -> loan mode
            DDS_OctetSeq hashes{};
            DDS_SampleInfoSeq infos{};

            auto rc = reader->take_raw(payloads, hashes, infos, ::DDS::HANDLE_NIL, nullptr,
                                        ::DDS::ANY_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE, 1);
            if (rc != ::DDS::RETCODE_OK) {
                std::fprintf(stderr, "FAIL: take_raw() returned %d\n", static_cast<int>(rc));
                std::exit(1);
            }
            if (payloads._length == 0) break;

            const auto &desc = payloads._buffer[0];
            const auto &info = infos._buffer[0];
            if (info.valid_data) {
                ::LoanedPing value{};
                ZidlCdrReader cdr_reader;
                if (zidl_cdr_reader_init(&cdr_reader, desc._buffer, desc._length) != 0) {
                    std::fprintf(stderr, "FAIL: zidl_cdr_reader_init() on loaned payload failed\n");
                    std::exit(1);
                }
                if (LoanedPing_deserialize(&cdr_reader, &value) != 0) {
                    std::fprintf(stderr, "FAIL: LoanedPing_deserialize() on loaned payload failed\n");
                    std::exit(1);
                }

                if (value.seq_num != state_->expected_next) {
                    std::fprintf(stderr, "FAIL: expected sequence=%d but got sequence=%d\n", state_->expected_next, value.seq_num);
                    std::exit(1);
                }
                std::printf("Subscriber: received (loan) sequence=%d\n", value.seq_num);
                state_->expected_next++;
            }

            if (reader->return_loan_raw(payloads, hashes, infos) != ::DDS::RETCODE_OK) {
                std::fprintf(stderr, "FAIL: return_loan_raw() failed\n");
                std::exit(1);
            }

            // Signal completion only after the loan is actually returned --
            // otherwise main() could race ahead and call delete_datareader()
            // while this loan is still outstanding, failing with
            // PRECONDITION_NOT_MET.
            if (state_->expected_next == SAMPLE_COUNT) {
                state_->all_received.store(true);
            }
        }
    }

private:
    SubState *state_;
};

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

    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    SubState state;
    auto listener = std::make_shared<SubListener>(&state);

    auto dr = sub->create_datareader(topic, dr_qos, listener, DDS_DATA_AVAILABLE_STATUS);
    if (!dr) {
        std::fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    std::printf("Create reader for topic: LoanedPing\n");

    std::printf("Subscriber: waiting for %d samples...\n", SAMPLE_COUNT);
    for (int waited_ms = 0; !state.all_received.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: only received %d/%d samples within %ds\n",
                          state.expected_next, SAMPLE_COUNT, RECEIVE_TIMEOUT_MS / 1000);
            return 1;
        }
        sleep_ms(POLL_PERIOD_MS);
    }

    // Every loan above was released via return_loan_raw -- an outstanding
    // loan would make delete_datareader fail with PRECONDITION_NOT_MET.
    if (sub->delete_datareader(dr) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: delete_datareader() did not return RETCODE_OK -- an outstanding loan leaked\n");
        return 1;
    }

    std::printf("Subscriber: received all %d samples in order.\n", SAMPLE_COUNT);
    return 0;
}
