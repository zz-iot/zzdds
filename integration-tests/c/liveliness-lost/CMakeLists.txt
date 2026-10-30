cmake_minimum_required(VERSION 3.14)
project(zzdds_integration_liveliness_lost_c C)

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

set(LIVELINESS_EVENT_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/liveliness_event.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/liveliness_event.h" "${GENERATED_DIR}/liveliness_event_cdr.c"
    COMMAND "${ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${LIVELINESS_EVENT_IDL}"
    DEPENDS "${LIVELINESS_EVENT_IDL}"
    COMMENT "Generating LivelinessEvent TypeSupport from liveliness_event.idl"
    VERBATIM
)
add_custom_target(generate_liveliness_lost_types DEPENDS "${GENERATED_DIR}/liveliness_event.h" "${GENERATED_DIR}/liveliness_event_cdr.c")

add_library(liveliness_lost_types STATIC "${GENERATED_DIR}/liveliness_event_cdr.c")
add_dependencies(liveliness_lost_types generate_liveliness_lost_types)
target_include_directories(liveliness_lost_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(liveliness_lost_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(liveliness_lost_publisher src/publisher.c)
target_link_libraries(liveliness_lost_publisher PRIVATE liveliness_lost_types ZZDDS::zzdds)

add_executable(liveliness_lost_subscriber src/subscriber.c)
target_link_libraries(liveliness_lost_subscriber PRIVATE liveliness_lost_types ZZDDS::zzdds)
