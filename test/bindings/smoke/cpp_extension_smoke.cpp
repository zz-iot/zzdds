// Binding smoke test for zzdds::Publisher::create_datawriter_ex and
// zzdds::Subscriber::create_datareader_ex through the installed C++ binding
// (zzdds_cpp.hpp's *Support wrappers). Compiled and run by
// `zig build test-bindings -Dcpp-binding=true`.
//
// Checks, for each side:
//   - the publisher/subscriber from create_publisher/create_subscriber upcasts
//     to the zzdds extension class (PublisherSupport/SubscriberSupport);
//   - the entity created with an extended listener receives its matched
//     callback and, with RELIABLE QoS on both sides, the reliable-ready
//     callback once the AckNack/Heartbeat handshake completes;
//   - the entity passed to the matched callback is the same C++ object the
//     application holds (one wrapper per entity; the extended-listener
//     bridges once built a separate base wrapper);
//   - that entity upcasts to zzdds::DataWriterImpl / zzdds::DataReaderImpl;
//   - a ContentFilteredTopic upcasts to zzdds::ContentFilteredTopicImpl, whose
//     set_filter_expression changes the filter without unmatching its reader.
#include "zzdds_cpp.hpp"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <thread>

#define CHECK(cond)                                                                   \
    do {                                                                              \
        if (!(cond)) {                                                                \
            std::fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond); \
            std::exit(1);                                                             \
        }                                                                             \
    } while (0)

namespace {

class WriterListener : public ::zzdds::DataWriterListenerExBase {
public:
    void on_publication_matched(std::shared_ptr<::DDS::DataWriter> writer, ::DDS::PublicationMatchedStatus status) override {
        std::lock_guard<std::mutex> lock(mu);
        if (status.current_count > 0) matched_writer = writer;
    }
    void on_reliable_reader_ready(::DDS::InstanceHandle_t, bool is_ready) override {
        if (is_ready) ready = true;
    }
    std::mutex mu;
    std::shared_ptr<::DDS::DataWriter> matched_writer;
    std::atomic<bool> ready{false};
};

class ReaderListener : public ::zzdds::DataReaderListenerExBase {
public:
    void on_subscription_matched(std::shared_ptr<::DDS::DataReader> reader, ::DDS::SubscriptionMatchedStatus status) override {
        std::lock_guard<std::mutex> lock(mu);
        if (status.current_count > 0) matched_reader = reader;
    }
    void on_reliable_writer_ready(::DDS::InstanceHandle_t, bool is_ready) override {
        if (is_ready) ready = true;
    }
    std::mutex mu;
    std::shared_ptr<::DDS::DataReader> matched_reader;
    std::atomic<bool> ready{false};
};

template <typename Pred>
bool wait_until(Pred pred) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (std::chrono::steady_clock::now() < deadline) {
        if (pred()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    return pred();
}

} // namespace

int main() {
    const char *base = std::getenv("ZZDDS_TEST_DOMAIN_BASE");
    const ::DDS::DomainId_t domain = base ? std::atoi(base) : 230;

    auto factory = zzdds::create_factory();
    CHECK(factory);
    auto dp_w = factory->create_participant(domain, ::DDS::DomainParticipantQos::default_value(), nullptr, 0);
    auto dp_r = factory->create_participant(domain, ::DDS::DomainParticipantQos::default_value(), nullptr, 0);
    CHECK(dp_w && dp_r);

    auto topic_w = dp_w->create_topic("CppExtensionSmoke", "CppExtensionSmokeType",
                                      ::DDS::TopicQos::default_value(), nullptr, 0);
    auto topic_r = dp_r->create_topic("CppExtensionSmoke", "CppExtensionSmokeType",
                                      ::DDS::TopicQos::default_value(), nullptr, 0);
    CHECK(topic_w && topic_r);

    auto pub = dp_w->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    auto sub = dp_r->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    CHECK(pub && sub);
    auto zpub = std::dynamic_pointer_cast<::zzdds::PublisherImpl>(pub);
    auto zsub = std::dynamic_pointer_cast<::zzdds::SubscriberImpl>(sub);
    CHECK(zpub && zsub);

    // RELIABLE on both sides, so the readiness callbacks wait for the
    // AckNack/Heartbeat handshake (BEST_EFFORT would make them fire at match).
    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    auto dw_qos = ::DDS::DataWriterQos::default_value();
    dw_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;

    auto rlistener = std::make_shared<ReaderListener>();
    auto dr = zsub->create_datareader_ex(
        std::static_pointer_cast<::zzdds::TopicImpl>(topic_r)->as_topic_description(),
        dr_qos, rlistener, ::DDS::SUBSCRIPTION_MATCHED_STATUS);
    CHECK(dr);
    CHECK(std::dynamic_pointer_cast<::zzdds::DataReaderImpl>(dr));

    auto wlistener = std::make_shared<WriterListener>();
    auto dw = zpub->create_datawriter_ex(topic_w, dw_qos, wlistener, ::DDS::PUBLICATION_MATCHED_STATUS);
    CHECK(dw);
    CHECK(std::dynamic_pointer_cast<::zzdds::DataWriterImpl>(dw));
    CHECK(dw->get_publisher() == pub);

    CHECK(wait_until([&] { std::lock_guard<std::mutex> l(wlistener->mu); return wlistener->matched_writer != nullptr; }));
    CHECK(wait_until([&] { std::lock_guard<std::mutex> l(rlistener->mu); return rlistener->matched_reader != nullptr; }));
    CHECK(wait_until([&] { return wlistener->ready.load(); }));
    CHECK(wait_until([&] { return rlistener->ready.load(); }));
    {
        std::lock_guard<std::mutex> l(wlistener->mu);
        CHECK(wlistener->matched_writer == dw);
    }
    {
        std::lock_guard<std::mutex> l(rlistener->mu);
        CHECK(rlistener->matched_reader == dr);
    }

    // zzdds::ContentFilteredTopic::set_filter_expression: a reader on the
    // filtered topic keeps its match across an expression change.
    auto cft = dp_r->create_contentfilteredtopic("CppExtensionSmokeFiltered", topic_r, "id > 10", {});
    CHECK(cft);
    auto zcft = std::dynamic_pointer_cast<::zzdds::ContentFilteredTopicImpl>(cft);
    CHECK(zcft);
    auto cft_reader = sub->create_datareader(cft, dr_qos, nullptr, 0);
    CHECK(cft_reader);
    CHECK(wait_until([&] {
        ::DDS::SubscriptionMatchedStatus st{};
        return cft_reader->get_subscription_matched_status(st) == ::DDS::RETCODE_OK && st.current_count == 1;
    }));
    CHECK(zcft->set_filter_expression("id < %0", {"5"}) == ::DDS::RETCODE_OK);
    CHECK(cft->get_filter_expression() == "id < %0");
    ::DDS::StringSeq params;
    CHECK(cft->get_expression_parameters(params) == ::DDS::RETCODE_OK);
    CHECK(params.size() == 1 && params[0] == "5");
    CHECK(zcft->set_filter_expression("id < < 5", {}) == ::DDS::RETCODE_BAD_PARAMETER);
    CHECK(cft->get_filter_expression() == "id < %0");
    {
        ::DDS::SubscriptionMatchedStatus st{};
        CHECK(cft_reader->get_subscription_matched_status(st) == ::DDS::RETCODE_OK);
        CHECK(st.current_count == 1 && st.total_count == 1);
    }
    CHECK(sub->delete_datareader(cft_reader) == ::DDS::RETCODE_OK);
    CHECK(dp_r->delete_contentfilteredtopic(cft) == ::DDS::RETCODE_OK);

    CHECK(pub->delete_datawriter(dw) == ::DDS::RETCODE_OK);
    CHECK(sub->delete_datareader(dr) == ::DDS::RETCODE_OK);
    CHECK(dp_w->delete_contained_entities() == ::DDS::RETCODE_OK);
    CHECK(dp_r->delete_contained_entities() == ::DDS::RETCODE_OK);
    CHECK(factory->delete_participant(dp_w) == ::DDS::RETCODE_OK);
    CHECK(factory->delete_participant(dp_r) == ::DDS::RETCODE_OK);
    std::printf("cpp_extension_smoke: OK\n");
    return 0;
}
