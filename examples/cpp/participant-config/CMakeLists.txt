cmake_minimum_required(VERSION 3.14)
project(zzdds_participant_config_cpp_example CXX C)

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

set(CONFIG_PING_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/config_ping.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/config_ping.hpp" "${GENERATED_DIR}/config_ping_cdr.cpp"
    COMMAND "${ZIDL_EXECUTABLE}" -b cpp --generate-interfaces --cpp-pmr-containers --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${CONFIG_PING_IDL}"
    DEPENDS "${CONFIG_PING_IDL}"
    COMMENT "Generating ConfigPing C++ TypeSupport from config_ping.idl"
    VERBATIM
)
add_custom_target(generate_config_ping_types DEPENDS "${GENERATED_DIR}/config_ping.hpp" "${GENERATED_DIR}/config_ping_cdr.cpp")

# zzdds's own pre-generated DCPS entity implementation, compiled directly by
# consumers -- see cpp/custom-allocator/CMakeLists.txt's matching comment
# ("three-artifact model": shared lib + these two generated .cpp files + headers).
add_library(participant_config_dcps_impl STATIC
    "${ZZDDS_DCPS_IMPL_CPP}"
    "${ZZDDS_ZZDDS_IMPL_CPP}"
    "${GENERATED_DIR}/config_ping_cdr.cpp"
)
add_dependencies(participant_config_dcps_impl generate_config_ping_types)
target_include_directories(participant_config_dcps_impl PUBLIC "${GENERATED_DIR}")
target_link_libraries(participant_config_dcps_impl PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(participant_config_pub src/publisher.cpp)
target_link_libraries(participant_config_pub PRIVATE participant_config_dcps_impl ZZDDS::zzdds)

add_executable(participant_config_sub src/subscriber.cpp)
target_link_libraries(participant_config_sub PRIVATE participant_config_dcps_impl ZZDDS::zzdds)
