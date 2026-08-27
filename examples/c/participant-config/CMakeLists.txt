cmake_minimum_required(VERSION 3.14)
project(zzdds_participant_config_c_example C)

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
    OUTPUT "${GENERATED_DIR}/config_ping.h" "${GENERATED_DIR}/config_ping_cdr.c"
    COMMAND "${ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${CONFIG_PING_IDL}"
    DEPENDS "${CONFIG_PING_IDL}"
    COMMENT "Generating ConfigPing TypeSupport from config_ping.idl"
    VERBATIM
)
add_custom_target(generate_config_ping_types DEPENDS "${GENERATED_DIR}/config_ping.h" "${GENERATED_DIR}/config_ping_cdr.c")

add_library(config_ping_types STATIC "${GENERATED_DIR}/config_ping_cdr.c")
add_dependencies(config_ping_types generate_config_ping_types)
target_include_directories(config_ping_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(config_ping_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(participant_config_pub src/publisher.c)
target_link_libraries(participant_config_pub PRIVATE config_ping_types ZZDDS::zzdds)

add_executable(participant_config_sub src/subscriber.c)
target_link_libraries(participant_config_sub PRIVATE config_ping_types ZZDDS::zzdds)
