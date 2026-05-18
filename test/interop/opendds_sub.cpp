/*
 * opendds_sub.cpp — OpenDDS interop subscriber.
 *
 * Waits up to 10 s for one HelloWorldData::Msg sample, prints it, exits 0.
 * Exits 1 on timeout.
 *
 * Scenario 4:  zzdds_interop_pub  &  ./opendds_sub -DCPSConfigFile rtps.ini
 * Expected:    opendds_sub receives "Hello from Zenzen DDS" and exits 0.
 */

#include "HelloWorldDataTypeSupportImpl.h"

#include <dds/DCPS/Marked_Default_Qos.h>
#include <dds/DCPS/Service_Participant.h>
#include <dds/DCPS/StaticIncludes.h>
#include <dds/DCPS/transport/rtps_udp/RtpsUdp.h>

#include <ace/OS_main.h>
#include <ace/OS_NS_unistd.h>

#include <iostream>
#include <cstdlib>

int ACE_TMAIN(int argc, ACE_TCHAR* argv[])
{
    DDS::DomainParticipantFactory_var dpf =
        TheParticipantFactoryWithArgs(argc, argv);

    DDS::DomainParticipant_var participant =
        dpf->create_participant(0, PARTICIPANT_QOS_DEFAULT,
                                nullptr, OpenDDS::DCPS::DEFAULT_STATUS_MASK);
    if (!participant) {
        std::cerr << "opendds_sub: create_participant failed\n";
        return EXIT_FAILURE;
    }

    HelloWorldData::MsgTypeSupport_var ts = new HelloWorldData::MsgTypeSupportImpl;
    if (ts->register_type(participant, "") != DDS::RETCODE_OK) {
        std::cerr << "opendds_sub: register_type failed\n";
        return EXIT_FAILURE;
    }

    CORBA::String_var type_name = ts->get_type_name();
    DDS::Topic_var topic =
        participant->create_topic("HelloWorldTopic", type_name,
                                  TOPIC_QOS_DEFAULT, nullptr,
                                  OpenDDS::DCPS::DEFAULT_STATUS_MASK);
    if (!topic) {
        std::cerr << "opendds_sub: create_topic failed\n";
        return EXIT_FAILURE;
    }

    DDS::Subscriber_var sub =
        participant->create_subscriber(SUBSCRIBER_QOS_DEFAULT, nullptr,
                                       OpenDDS::DCPS::DEFAULT_STATUS_MASK);
    if (!sub) {
        std::cerr << "opendds_sub: create_subscriber failed\n";
        return EXIT_FAILURE;
    }

    DDS::DataReaderQos dr_qos;
    sub->get_default_datareader_qos(dr_qos);
    dr_qos.reliability.kind = DDS::RELIABLE_RELIABILITY_QOS;

    DDS::DataReader_var reader =
        sub->create_datareader(topic, dr_qos, nullptr,
                               OpenDDS::DCPS::DEFAULT_STATUS_MASK);
    if (!reader) {
        std::cerr << "opendds_sub: create_datareader failed\n";
        return EXIT_FAILURE;
    }

    HelloWorldData::MsgDataReader_var mr =
        HelloWorldData::MsgDataReader::_narrow(reader);
    if (!mr) {
        std::cerr << "opendds_sub: _narrow failed\n";
        return EXIT_FAILURE;
    }

    /* Poll up to 10 s (200 × 50 ms). */
    for (int i = 0; i < 200; i++) {
        HelloWorldData::Msg msg;
        DDS::SampleInfo info;
        DDS::ReturnCode_t rc = mr->take_next_sample(msg, info);
        if (rc == DDS::RETCODE_OK && info.valid_data) {
            std::cout << "opendds_sub: received userID=" << msg.userID
                      << " message=\"" << msg.message.in() << "\"\n";
            participant->delete_contained_entities();
            dpf->delete_participant(participant);
            TheServiceParticipant->shutdown();
            return EXIT_SUCCESS;
        }
        ACE_OS::sleep(ACE_Time_Value(0, 50000)); /* 50ms */
    }

    std::cerr << "opendds_sub: timeout — no sample received\n";
    participant->delete_contained_entities();
    dpf->delete_participant(participant);
    TheServiceParticipant->shutdown();
    return EXIT_FAILURE;
}
