cmake_minimum_required(VERSION 3.14)
project(zzdds_integration_sample_rejected_lost_cpp CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(ZZDDS REQUIRED)

if(NOT DEFINED ZIDL_EXECUTABLE)
    set(ZIDL_EXECUTABLE "${ZZDDS_ZIDL_EXECUTABLE}")
endif()

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(STATUS_EVENT_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/status_event.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/status_event.hpp" "${GENERATED_DIR}/status_event_cdr.cpp"
    COMMAND "${ZIDL_EXECUTABLE}" -b cpp --generate-interfaces --cpp-pmr-containers --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${STATUS_EVENT_IDL}"
    DEPENDS "${STATUS_EVENT_IDL}"
    COMMENT "Generating StatusEvent C++ TypeSupport from status_event.idl"
    VERBATIM
)
add_custom_target(generate_sample_rejected_lost_types DEPENDS "${GENERATED_DIR}/status_event.hpp" "${GENERATED_DIR}/status_event_cdr.cpp")

add_library(sample_rejected_lost_dcps_impl STATIC
    "${ZZDDS_DCPS_IMPL_CPP}"
    "${ZZDDS_ZZDDS_IMPL_CPP}"
    "${GENERATED_DIR}/status_event_cdr.cpp"
)
add_dependencies(sample_rejected_lost_dcps_impl generate_sample_rejected_lost_types)
target_include_directories(sample_rejected_lost_dcps_impl PUBLIC "${GENERATED_DIR}")
target_link_libraries(sample_rejected_lost_dcps_impl PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(sample_rejected_lost_pub src/publisher.cpp)
target_link_libraries(sample_rejected_lost_pub PRIVATE sample_rejected_lost_dcps_impl ZZDDS::zzdds)

add_executable(sample_rejected_lost_sub src/subscriber.cpp)
target_link_libraries(sample_rejected_lost_sub PRIVATE sample_rejected_lost_dcps_impl ZZDDS::zzdds)
