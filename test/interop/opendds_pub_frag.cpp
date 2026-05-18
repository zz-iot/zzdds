/*
 * opendds_pub_frag.cpp — OpenDDS interop publisher (DATA_FRAG path).
 *
 * Sends a HelloWorldData::Msg with a 2000-byte message string — well above
 * OpenDDS's hardcoded FRAG_SIZE of 1024 bytes — so OpenDDS must emit
 * DATA_FRAG submessages.  Exercises Zenzen DDS's DATA_FRAG reassembly path.
 *
 * Test scenario 6:  ./zzdds_interop_sub  &  ./opendds_pub_frag -DCPSConfigFile rtps.ini
 * Expected result:  zzdds_interop_sub reassembles fragments, prints the
 *                   message, and exits 0.
 */

#include "HelloWorldDataTypeSupportImpl.h"

#include <dds/DCPS/Marked_Default_Qos.h>
#include <dds/DCPS/Service_Participant.h>
#include <dds/DCPS/StaticIncludes.h>
#include <dds/DCPS/WaitSet.h>
#include <dds/DCPS/transport/rtps_udp/RtpsUdp.h>

#include <ace/OS_main.h>
#include <ace/OS_NS_unistd.h>

#include <iostream>
#include <cstring>
#include <cstdlib>

static const int MSG_LEN = 2000;

int ACE_TMAIN(int argc, ACE_TCHAR* argv[])
{
    DDS::DomainParticipantFactory_var dpf =
        TheParticipantFactoryWithArgs(argc, argv);

    DDS::DomainParticipant_var participant =
        dpf->create_participant(0, PARTICIPANT_QOS_DEFAULT,
                                nullptr, OpenDDS::DCPS::DEFAULT_STATUS_MASK);
    if (!participant) {
        std::cerr << "opendds_pub_frag: create_participant failed\n";
        return EXIT_FAILURE;
    }

    HelloWorldData::MsgTypeSupport_var ts = new HelloWorldData::MsgTypeSupportImpl;
    if (ts->register_type(participant, "") != DDS::RETCODE_OK) {
        std::cerr << "opendds_pub_frag: register_type failed\n";
        return EXIT_FAILURE;
    }

    CORBA::String_var type_name = ts->get_type_name();
    DDS::Topic_var topic =
        participant->create_topic("HelloWorldTopic", type_name,
                                  TOPIC_QOS_DEFAULT, nullptr,
                                  OpenDDS::DCPS::DEFAULT_STATUS_MASK);
    if (!topic) {
        std::cerr << "opendds_pub_frag: create_topic failed\n";
        return EXIT_FAILURE;
    }

    DDS::Publisher_var pub =
        participant->create_publisher(PUBLISHER_QOS_DEFAULT, nullptr,
                                      OpenDDS::DCPS::DEFAULT_STATUS_MASK);
    if (!pub) {
        std::cerr << "opendds_pub_frag: create_publisher failed\n";
        return EXIT_FAILURE;
    }

    DDS::DataWriterQos dw_qos;
    pub->get_default_datawriter_qos(dw_qos);
    dw_qos.reliability.kind = DDS::RELIABLE_RELIABILITY_QOS;
    dw_qos.reliability.max_blocking_time.sec = 1;
    dw_qos.reliability.max_blocking_time.nanosec = 0;

    DDS::DataWriter_var writer =
        pub->create_datawriter(topic, dw_qos, nullptr,
                               OpenDDS::DCPS::DEFAULT_STATUS_MASK);
    if (!writer) {
        std::cerr << "opendds_pub_frag: create_datawriter failed\n";
        return EXIT_FAILURE;
    }

    /* Wait up to 5 s for a matching reader. */
    DDS::StatusCondition_var sc = writer->get_statuscondition();
    sc->set_enabled_statuses(DDS::PUBLICATION_MATCHED_STATUS);
    DDS::WaitSet_var ws = new DDS::WaitSet;
    ws->attach_condition(sc);
    DDS::Duration_t timeout = {5, 0};
    DDS::ConditionSeq conditions;
    ws->wait(conditions, timeout);
    ws->detach_condition(sc);

    DDS::PublicationMatchedStatus pms;
    writer->get_publication_matched_status(pms);
    if (pms.current_count == 0) {
        std::cerr << "opendds_pub_frag: no matching reader found within 5s\n";
        participant->delete_contained_entities();
        dpf->delete_participant(participant);
        TheServiceParticipant->shutdown();
        return EXIT_FAILURE;
    }

    /* Build a 2000-char message: prefix + '.' padding. */
    const char *prefix = "Hello from OpenDDS (frag test) ";
    char buf[MSG_LEN + 1];
    size_t plen = std::strlen(prefix);
    std::memcpy(buf, prefix, plen);
    std::memset(buf + plen, '.', MSG_LEN - plen);
    buf[MSG_LEN] = '\0';

    HelloWorldData::MsgDataWriter_var mw =
        HelloWorldData::MsgDataWriter::_narrow(writer);
    if (!mw) {
        std::cerr << "opendds_pub_frag: _narrow failed\n";
        return EXIT_FAILURE;
    }

    HelloWorldData::Msg msg;
    msg.userID  = 43;
    msg.message = CORBA::string_dup(buf);

    if (mw->write(msg, DDS::HANDLE_NIL) != DDS::RETCODE_OK) {
        std::cerr << "opendds_pub_frag: write failed\n";
        participant->delete_contained_entities();
        dpf->delete_participant(participant);
        TheServiceParticipant->shutdown();
        return EXIT_FAILURE;
    }

    std::cout << "opendds_pub_frag: sent userID=" << msg.userID
              << " message[0..30]=\"" << std::string(buf, 30) << "...\"\n";

    ACE_OS::sleep(ACE_Time_Value(2, 0)); /* 2 s for reliable delivery + NACK_FRAG */

    participant->delete_contained_entities();
    dpf->delete_participant(participant);
    TheServiceParticipant->shutdown();
    return EXIT_SUCCESS;
}
