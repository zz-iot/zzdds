cmake_minimum_required(VERSION 3.14)
project(zzdds_integration_enable_defer_cpp CXX C)

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

set(CONFIG_EVENT_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/config_event.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/config_event.hpp" "${GENERATED_DIR}/config_event_cdr.cpp"
    COMMAND "${ZIDL_EXECUTABLE}" -b cpp --generate-interfaces --cpp-pmr-containers --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${CONFIG_EVENT_IDL}"
    DEPENDS "${CONFIG_EVENT_IDL}"
    COMMENT "Generating ConfigEvent C++ TypeSupport from config_event.idl"
    VERBATIM
)
add_custom_target(generate_enable_defer_types DEPENDS "${GENERATED_DIR}/config_event.hpp" "${GENERATED_DIR}/config_event_cdr.cpp")

add_library(enable_defer_dcps_impl STATIC
    "${ZZDDS_DCPS_IMPL_CPP}"
    "${ZZDDS_ZZDDS_IMPL_CPP}"
    "${GENERATED_DIR}/config_event_cdr.cpp"
)
add_dependencies(enable_defer_dcps_impl generate_enable_defer_types)
target_include_directories(enable_defer_dcps_impl PUBLIC "${GENERATED_DIR}")
target_link_libraries(enable_defer_dcps_impl PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(enable_defer_configurer src/configurer.cpp)
target_link_libraries(enable_defer_configurer PRIVATE enable_defer_dcps_impl ZZDDS::zzdds)

add_executable(enable_defer_peer src/peer.cpp)
target_link_libraries(enable_defer_peer PRIVATE enable_defer_dcps_impl ZZDDS::zzdds)
