cmake_minimum_required(VERSION 3.14)
project(zzdds_integration_source_timestamp_c C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(MSVC)
    # MSVC gates <stdatomic.h> behind this flag (error C1189 "C atomic support
    # is not enabled"); it needs /std:c11, which CMAKE_C_STANDARD 11 sets.
    add_compile_options(/experimental:c11atomics)
    # Native config parsing needs more than MSVC's default 1 MiB stack.
    add_link_options(/STACK:8388608)
endif()

find_package(ZZDDS REQUIRED)

if(NOT DEFINED ZIDL_EXECUTABLE)
    set(ZIDL_EXECUTABLE "${ZZDDS_ZIDL_EXECUTABLE}")
endif()

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(TIMESTAMP_EVENT_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/timestamp_event.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/timestamp_event.h" "${GENERATED_DIR}/timestamp_event_cdr.c"
    COMMAND "${ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${TIMESTAMP_EVENT_IDL}"
    DEPENDS "${TIMESTAMP_EVENT_IDL}"
    COMMENT "Generating TimestampEvent TypeSupport from timestamp_event.idl"
    VERBATIM
)
add_custom_target(generate_source_timestamp_types DEPENDS "${GENERATED_DIR}/timestamp_event.h" "${GENERATED_DIR}/timestamp_event_cdr.c")

add_library(source_timestamp_types STATIC "${GENERATED_DIR}/timestamp_event_cdr.c")
add_dependencies(source_timestamp_types generate_source_timestamp_types)
target_include_directories(source_timestamp_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(source_timestamp_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(source_timestamp_publisher src/publisher.c)
target_link_libraries(source_timestamp_publisher PRIVATE source_timestamp_types ZZDDS::zzdds)

add_executable(source_timestamp_subscriber src/subscriber.c)
target_link_libraries(source_timestamp_subscriber PRIVATE source_timestamp_types ZZDDS::zzdds)
