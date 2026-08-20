cmake_minimum_required(VERSION 3.14)
project(zzdds_discovery_cpp_example CXX C)

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

set(DISCOVERY_PING_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/discovery_ping.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/discovery_ping.hpp" "${GENERATED_DIR}/discovery_ping_cdr.cpp"
    COMMAND "${ZIDL_EXECUTABLE}" -b cpp --generate-interfaces --cpp-pmr-containers --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${DISCOVERY_PING_IDL}"
    DEPENDS "${DISCOVERY_PING_IDL}"
    COMMENT "Generating DiscoveryPing C++ TypeSupport from discovery_ping.idl"
    VERBATIM
)
add_custom_target(generate_discovery_ping_types DEPENDS "${GENERATED_DIR}/discovery_ping.hpp" "${GENERATED_DIR}/discovery_ping_cdr.cpp")

# zzdds's own pre-generated DCPS entity implementation, compiled directly by
# consumers -- see cpp/custom-allocator/CMakeLists.txt's matching comment
# ("three-artifact model": shared lib + these two generated .cpp files + headers).
add_library(dcps_impl STATIC
    "${ZZDDS_DCPS_IMPL_CPP}"
    "${ZZDDS_ZZDDS_IMPL_CPP}"
    "${GENERATED_DIR}/discovery_ping_cdr.cpp"
)
add_dependencies(dcps_impl generate_discovery_ping_types)
target_include_directories(dcps_impl PUBLIC "${GENERATED_DIR}")
target_link_libraries(dcps_impl PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(discovery_pub src/publisher.cpp)
target_link_libraries(discovery_pub PRIVATE dcps_impl ZZDDS::zzdds)

add_executable(discovery_sub src/subscriber.cpp)
target_link_libraries(discovery_sub PRIVATE dcps_impl ZZDDS::zzdds)
