cmake_minimum_required(VERSION 3.14)
project(zzdds_integration_wait_for_historical_data_cpp CXX C)

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

set(HISTORY_EVENT_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/history_event.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/history_event.hpp" "${GENERATED_DIR}/history_event_cdr.cpp"
    COMMAND "${ZIDL_EXECUTABLE}" -b cpp --generate-interfaces --cpp-pmr-containers --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${HISTORY_EVENT_IDL}"
    DEPENDS "${HISTORY_EVENT_IDL}"
    COMMENT "Generating HistoryEvent C++ TypeSupport from history_event.idl"
    VERBATIM
)
add_custom_target(generate_wait_for_historical_data_types DEPENDS "${GENERATED_DIR}/history_event.hpp" "${GENERATED_DIR}/history_event_cdr.cpp")

add_library(wait_for_historical_data_dcps_impl STATIC
    "${ZZDDS_DCPS_IMPL_CPP}"
    "${ZZDDS_ZZDDS_IMPL_CPP}"
    "${GENERATED_DIR}/history_event_cdr.cpp"
)
add_dependencies(wait_for_historical_data_dcps_impl generate_wait_for_historical_data_types)
target_include_directories(wait_for_historical_data_dcps_impl PUBLIC "${GENERATED_DIR}")
target_link_libraries(wait_for_historical_data_dcps_impl PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(wait_for_historical_data_publisher src/publisher.cpp)
target_link_libraries(wait_for_historical_data_publisher PRIVATE wait_for_historical_data_dcps_impl ZZDDS::zzdds)

add_executable(wait_for_historical_data_subscriber src/subscriber.cpp)
target_link_libraries(wait_for_historical_data_subscriber PRIVATE wait_for_historical_data_dcps_impl ZZDDS::zzdds)
