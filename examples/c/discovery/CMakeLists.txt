cmake_minimum_required(VERSION 3.14)
project(zzdds_discovery_c_example C)

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
    OUTPUT "${GENERATED_DIR}/discovery_ping.h" "${GENERATED_DIR}/discovery_ping_cdr.c"
    COMMAND "${ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${DISCOVERY_PING_IDL}"
    DEPENDS "${DISCOVERY_PING_IDL}"
    COMMENT "Generating DiscoveryPing TypeSupport from discovery_ping.idl"
    VERBATIM
)
add_custom_target(generate_discovery_ping_types DEPENDS "${GENERATED_DIR}/discovery_ping.h" "${GENERATED_DIR}/discovery_ping_cdr.c")

add_library(discovery_ping_types STATIC "${GENERATED_DIR}/discovery_ping_cdr.c")
add_dependencies(discovery_ping_types generate_discovery_ping_types)
target_include_directories(discovery_ping_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(discovery_ping_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(discovery_pub src/publisher.c)
target_link_libraries(discovery_pub PRIVATE discovery_ping_types ZZDDS::zzdds)

add_executable(discovery_sub src/subscriber.c)
target_link_libraries(discovery_sub PRIVATE discovery_ping_types ZZDDS::zzdds)
