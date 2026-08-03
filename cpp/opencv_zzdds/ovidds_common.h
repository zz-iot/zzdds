#pragma once

#include <cstdint>

constexpr int32_t     DOMAIN           = 4;
constexpr const char* FRAME_TOPIC_NAME = "ovidds_frames";

// Type name registered with DDS.  Must match the name passed to create_topic().
// zidl now generates the IDL-scoped name as the default ("ovidds::Frame"),
// matching the DDS spec and interoperating correctly with other implementations.
constexpr const char* FRAME_TYPE_NAME  = "ovidds::Frame";
