// Independent Fast DDS 3 peer. The two tiny final IDL layouts are implemented
// directly here: no zidl runtime, generated code, or loadable ABI dependency.
#include <fastdds/dds/domain/DomainParticipantFactory.hpp>
#include <fastdds/dds/domain/DomainParticipant.hpp>
#include <fastdds/dds/domain/DomainParticipantListener.hpp>
#include <fastdds/dds/subscriber/Subscriber.hpp>
#include <fastdds/dds/subscriber/DataReader.hpp>
#include <fastdds/dds/subscriber/SampleInfo.hpp>
#include <fastdds/dds/topic/TopicDataType.hpp>
#include <fastdds/dds/topic/TypeSupport.hpp>
#include <fastdds/rtps/transport/UDPv4TransportDescriptor.hpp>
#include <array>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <thread>

namespace fd = ::eprosima::fastdds::dds;
namespace rtps = eprosima::fastdds::rtps;
struct Sample { uint32_t first = 0, second = 0; };
class WireType final : public fd::TopicDataType {
    bool keyed_;
public:
    explicit WireType(bool keyed) : keyed_(keyed) {
        set_name(keyed ? "LoadedDemo::Reading" : "LoadedDemo::Pulse");
        max_serialized_type_size = keyed ? 12 : 8;
        is_compute_key_provided = keyed;
    }
    bool serialize(const void* const, rtps::SerializedPayload_t&, fd::DataRepresentationId_t) override {
        return false; // receive-only peer
    }
    bool deserialize(rtps::SerializedPayload_t& payload, void* data) override {
        const auto* p = payload.data;
        if (payload.length != max_serialized_type_size || p[0] != 0 || p[1] > 1 || p[2] != 0 || p[3] != 0) return false;
        auto read = [p](unsigned offset) {
            uint32_t value = 0;
            for (unsigned i = 0; i < 4; ++i) value |= uint32_t(p[offset + i]) << (8 * (p[1] ? i : 3 - i));
            return value;
        };
        auto& sample = *static_cast<Sample*>(data);
        sample.first = read(4);
        sample.second = keyed_ ? read(8) : 0;
        return true;
    }
    uint32_t calculate_serialized_size(const void* const, fd::DataRepresentationId_t) override { return max_serialized_type_size; }
    void* create_data() override { return new Sample; }
    void delete_data(void* data) override { delete static_cast<Sample*>(data); }
    bool compute_key(const void* const data, rtps::InstanceHandle_t& handle, bool force_md5) override {
        if (!keyed_ || force_md5) return false;
        const auto key = static_cast<const Sample*>(data)->first;
        for (unsigned i = 0; i < 16; ++i) handle.value[i] = i < 4 ? uint8_t(key >> (8 * (3 - i))) : 0;
        return true;
    }
    bool compute_key(rtps::SerializedPayload_t& payload, rtps::InstanceHandle_t& handle, bool force_md5) override {
        Sample sample;
        return deserialize(payload, &sample) && compute_key(&sample, handle, force_md5);
    }
};
class DiscoveryLog : public fd::DomainParticipantListener {
public:
    void on_participant_discovery(fd::DomainParticipant*, rtps::ParticipantDiscoveryStatus reason, const fd::ParticipantBuiltinTopicData&, bool& ignore) override {
        ignore = false;
        std::cerr << "Fast DDS participant discovery: " << static_cast<int>(reason) << '\n';
    }
    void on_requested_incompatible_qos(fd::DataReader*, const fd::RequestedIncompatibleQosStatus& status) override {
        std::cerr << "Fast DDS incompatible QoS: " << status.last_policy_id << '\n';
    }
    void on_subscription_matched(fd::DataReader*, const fd::SubscriptionMatchedStatus& status) override {
        std::cerr << "Fast DDS matched writers: " << status.current_count << '\n';
    }
};
struct ParticipantOwner {
    fd::DomainParticipant* value;
    ~ParticipantOwner() {
        if (value) {
            value->delete_contained_entities();
            fd::DomainParticipantFactory::get_instance()->delete_participant(value);
        }
    }
};
int main(int argc, char** argv) {
    try {
        if (argc != 2) throw std::runtime_error("usage: typesupport-fastdds-sub DOMAIN");
        const auto domain = std::stoul(argv[1]);
        if (domain > 232) throw std::runtime_error("expected UDP domain 0..232");
        DiscoveryLog listener;
        fd::DomainParticipantQos pqos;
        pqos.transport().use_builtin_transports = false;
        pqos.transport().user_transports.push_back(std::make_shared<rtps::UDPv4TransportDescriptor>());
        ParticipantOwner participant{fd::DomainParticipantFactory::get_instance()->create_participant(static_cast<uint32_t>(domain), pqos, &listener)};
        if (!participant.value) throw std::runtime_error("participant creation failed");
        std::array<fd::TypeSupport, 2> types{fd::TypeSupport(new WireType(true)), fd::TypeSupport(new WireType(false))};
        auto* subscriber = participant.value->create_subscriber(fd::SUBSCRIBER_QOS_DEFAULT);
        if (!subscriber) throw std::runtime_error("subscriber creation failed");
        std::array<fd::DataReader*, 2> readers{};
        const char* topics[] = {"LoadedReadings", "LoadedPulses"};
        for (unsigned i = 0; i < 2; ++i) {
            if (types[i].register_type(participant.value) != fd::RETCODE_OK) throw std::runtime_error("register_type failed");
            auto* topic = participant.value->create_topic(topics[i], types[i].get_type_name(), fd::TOPIC_QOS_DEFAULT);
            if (!topic) throw std::runtime_error("topic creation failed");
            fd::DataReaderQos qos;
            qos.reliability().kind = fd::RELIABLE_RELIABILITY_QOS;
            qos.history().kind = fd::KEEP_ALL_HISTORY_QOS;
            qos.representation().m_value = {fd::XCDR_DATA_REPRESENTATION};
            readers[i] = subscriber->create_datareader(topic, qos);
            if (!readers[i]) throw std::runtime_error("reader creation failed");
        }
        std::array<bool, 3> seen{};
        std::array<rtps::InstanceHandle_t, 2> handles{};
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(25);
        while (!(seen[0] && seen[1] && seen[2])) {
            for (unsigned i = 0; i < 2; ++i) {
                Sample sample;
                fd::SampleInfo info;
                while (readers[i]->take_next_sample(&sample, &info) == fd::RETCODE_OK) {
                    if (!info.valid_data) continue;
                    if (i == 0 && (sample.first == 1 || sample.first == 2) && sample.second == sample.first * 101) {
                        const auto index = sample.first - 1;
                        seen[index] = true;
                        handles[index] = info.instance_handle;
                    } else if (i == 1 && sample.first == 7) seen[2] = true;
                    else throw std::runtime_error("unexpected decoded sample");
                }
            }
            if (std::chrono::steady_clock::now() > deadline) throw std::runtime_error("reception timeout");
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
        if (handles[0] == handles[1] || handles[0] == rtps::c_InstanceHandle_Unknown || handles[1] == rtps::c_InstanceHandle_Unknown) throw std::runtime_error("invalid keyed instance separation");
        std::cout << "PASS Fast DDS received two distinct keyed instances and one keyless pulse\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
