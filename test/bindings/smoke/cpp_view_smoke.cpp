// Read view types over a live reader (zidl --generate-views): a writer and a
// reader in one participant, a sample written and taken with take_view into a
// ViewLoan, whose view holds the decoded members in place until reset() ends
// the loan. Then the write twin, a builder: filled in place in a BuilderLoan
// and published, or cancelled. Compiled and run by
// `zig build test-bindings -Dcpp-binding=true`.

#include "view_smoke.hpp"
#include "zzdds_c.h"

#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

static void sleep_ms(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

// The domain build.zig gives this binary (ZZDDS_TEST_DOMAIN_BASE, as
// test/support/domain.zig reads it), or 99 run directly.
static uint32_t test_domain() {
    const char *base = std::getenv("ZZDDS_TEST_DOMAIN_BASE");
    return base != nullptr ? static_cast<uint32_t>(std::strtoul(base, nullptr, 10)) : 99u;
}

constexpr int kTimeoutMs = 10000;
constexpr int kPollMs = 10;

int main() {
    zzdds_DomainParticipantFactory factory = zzdds_DomainParticipantFactory_create();
    assert(factory != nullptr);
    DDS_DomainParticipantFactory dds_factory = zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory);
    DDS_DomainParticipant dp = DDS_DomainParticipantFactory_create_participant(dds_factory, test_domain(), nullptr, nullptr, 0);
    assert(dp != nullptr);
    assert(ViewSmokeFrameTypeSupport::register_type(dp, "ViewSmokeFrame") == DDS_RETCODE_OK);
    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "ViewSmokeCpp", "ViewSmokeFrame", nullptr, nullptr, 0);
    assert(topic != nullptr);

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, nullptr, nullptr, 0);
    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;
    DDS_DataReader dr = DDS_Subscriber_create_datareader(sub, DDS_Topic_as_DDS_TopicDescription(topic), &dr_qos, nullptr, 0);
    assert(dr != nullptr);

    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, nullptr, nullptr, 0);
    DDS_DataWriterQos dw_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &dw_qos);
    dw_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;
    DDS_DataWriter dw = DDS_Publisher_create_datawriter(pub, topic, &dw_qos, nullptr, 0);
    assert(dw != nullptr);

    // The reader matches before anything is written.
    for (int waited = 0;; waited += kPollMs) {
        DDS_PublicationMatchedStatus status;
        assert(DDS_DataWriter_get_publication_matched_status(dw, &status) == DDS_RETCODE_OK);
        if (status.current_count >= 1) break;
        assert(waited < kTimeoutMs);
        sleep_ms(kPollMs);
    }

    ViewSmokeFrame sample{};
    sample.id = 3u;
    sample.label = "view smoke";
    for (int i = 0; i < 64; ++i) sample.payload.push_back(static_cast<uint8_t>(i * 3));
    sample.samples = {1.5, -2.25, 1e300};
    ViewSmokeFrameDataWriter writer(dw, ZIDL_XCDR2);
    assert(writer.write(sample) == DDS_RETCODE_OK);

    ViewSmokeFrameDataReader reader(dr);
    // take_view, waiting up to kTimeoutMs for a sample.
    auto take_view_within = [&reader](ViewSmokeFrameDataReader::ViewLoan &out) {
        for (int waited = 0;; waited += kPollMs) {
            const DDS_ReturnCode_t rc = reader.take_view(out);
            if (rc != DDS_RETCODE_NO_DATA || waited >= kTimeoutMs) return rc;
            sleep_ms(kPollMs);
        }
    };
    ViewSmokeFrameDataReader::ViewLoan loan;
    DDS_ReturnCode_t rc = take_view_within(loan);
    assert(rc == DDS_RETCODE_OK && loan.active() && loan.info().valid_data);

    const ViewSmokeFrameView &view = loan.view();
    assert(view.id == 3u && view.label == "view smoke");
    // Decoded in place: the members sit at their XCDR2 offsets from each other
    // in one buffer, the loaned payload (a ViewLoan does not expose its bytes,
    // and fields copied out would each have their own storage). After the
    // label's length and its 11 bytes with the NUL, padding to 4 and the
    // payload's count, the payload is 16 bytes on; 64 octets and the samples'
    // count later, the doubles (4-aligned in XCDR2) are 84 bytes on.
    const auto *label_at = reinterpret_cast<const uint8_t *>(view.label.data());
    assert(view.payload.c_view().data == label_at + 16);
    assert(view.samples.c_view().data == label_at + 84);
    assert(view.payload.size() == 64);
    const uint8_t *bytes = view.payload.as_native();  // octets: always in place
    assert(bytes != nullptr && std::memcmp(bytes, sample.payload.data(), 64) == 0);
    assert(view.samples.to_vector() == sample.samples);

    // A ViewLoan moved keeps the loan; reset() ends it, once.
    ViewSmokeFrameDataReader::ViewLoan moved = std::move(loan);
    assert(!loan.active() && moved.active() && moved.view().label == "view smoke");
    moved.reset();
    assert(!moved.active());

    // Taken, so nothing is left.
    assert(reader.take_view(moved) == DDS_RETCODE_NO_DATA && !moved.active());

    // A builder's loan cancelled, or destroyed active, publishes nothing.
    ViewSmokeFrameBuilder cancelled{};
    cancelled.id = 5u;
    cancelled.label = "cancelled";
    cancelled.payload.resize(8);
    ViewSmokeFrameDataWriter::BuilderLoan built;
    assert(writer.loan_builder(cancelled, built) == DDS_RETCODE_OK && built.active());
    assert(writer.cancel_builder(built) == DDS_RETCODE_OK && !built.active());
    {
        ViewSmokeFrameDataWriter::BuilderLoan dropped;
        assert(writer.loan_builder(cancelled, dropped) == DDS_RETCODE_OK && dropped.active());
    }

    // One filled in place and published reads back as if written.
    ViewSmokeFrameBuilder builder{};
    builder.id = 4u;
    builder.label = "builder smoke";
    builder.payload.resize(32);
    builder.samples.resize(2);
    assert(writer.loan_builder(builder, built) == DDS_RETCODE_OK && built.active());
    uint8_t *octets = built.builder().payload.as_native();  // octets: always aligned
    assert(octets != nullptr);
    for (int i = 0; i < 32; ++i) octets[i] = static_cast<uint8_t>(255 - i);
    const std::vector<double> built_samples = {3.0, -0.5};
    built.builder().samples.copy_from(built_samples.data());
    assert(writer.publish_builder(built) == DDS_RETCODE_OK && !built.active());

    rc = take_view_within(moved);
    assert(rc == DDS_RETCODE_OK && moved.active() && moved.info().valid_data);
    const ViewSmokeFrameView &built_view = moved.view();
    assert(built_view.id == 4u && built_view.label == "builder smoke");
    assert(built_view.payload.size() == 32);
    for (int i = 0; i < 32; ++i) assert(built_view.payload.as_native()[i] == static_cast<uint8_t>(255 - i));
    assert(built_view.samples.to_vector() == built_samples);
    moved.reset();
    assert(reader.take_view(moved) == DDS_RETCODE_NO_DATA);

    assert(DDS_DomainParticipant_delete_contained_entities(dp) == DDS_RETCODE_OK);
    assert(DDS_DomainParticipantFactory_delete_participant(dds_factory, dp) == DDS_RETCODE_OK);
    assert(zzdds_DomainParticipantFactory_destroy(factory) == DDS_RETCODE_OK);
    std::puts("cpp_view_smoke: OK");
    return 0;
}
