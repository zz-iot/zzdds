cmake_minimum_required(VERSION 3.14)
project(zzdds_integration_cft_reconfigure_cpp CXX C)

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

set(CFT_EVENT_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/cft_event.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/cft_event.hpp" "${GENERATED_DIR}/cft_event_cdr.cpp"
    COMMAND "${ZIDL_EXECUTABLE}" -b cpp --generate-interfaces --cpp-pmr-containers --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${CFT_EVENT_IDL}"
    DEPENDS "${CFT_EVENT_IDL}"
    COMMENT "Generating CftEvent C++ TypeSupport from cft_event.idl"
    VERBATIM
)
add_custom_target(generate_cft_reconfigure_types DEPENDS "${GENERATED_DIR}/cft_event.hpp" "${GENERATED_DIR}/cft_event_cdr.cpp")

add_library(cft_reconfigure_dcps_impl STATIC
    "${ZZDDS_DCPS_IMPL_CPP}"
    "${ZZDDS_ZZDDS_IMPL_CPP}"
    "${GENERATED_DIR}/cft_event_cdr.cpp"
)
add_dependencies(cft_reconfigure_dcps_impl generate_cft_reconfigure_types)
target_include_directories(cft_reconfigure_dcps_impl PUBLIC "${GENERATED_DIR}")
target_link_libraries(cft_reconfigure_dcps_impl PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(cft_reconfigure_publisher src/publisher.cpp)
target_link_libraries(cft_reconfigure_publisher PRIVATE cft_reconfigure_dcps_impl ZZDDS::zzdds)

add_executable(cft_reconfigure_subscriber src/subscriber.cpp)
target_link_libraries(cft_reconfigure_subscriber PRIVATE cft_reconfigure_dcps_impl ZZDDS::zzdds)
