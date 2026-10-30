cmake_minimum_required(VERSION 3.14)
project(zzdds_integration_ignore_entities_c C)

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

set(IGNORE_EVENT_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/ignore_event.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/ignore_event.h" "${GENERATED_DIR}/ignore_event_cdr.c"
    COMMAND "${ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${IGNORE_EVENT_IDL}"
    DEPENDS "${IGNORE_EVENT_IDL}"
    COMMENT "Generating IgnoreEvent TypeSupport from ignore_event.idl"
    VERBATIM
)
add_custom_target(generate_ignore_entities_types DEPENDS "${GENERATED_DIR}/ignore_event.h" "${GENERATED_DIR}/ignore_event_cdr.c")

add_library(ignore_entities_types STATIC "${GENERATED_DIR}/ignore_event_cdr.c")
add_dependencies(ignore_entities_types generate_ignore_entities_types)
target_include_directories(ignore_entities_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(ignore_entities_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(ignore_entities_ignorer src/ignorer.c)
target_link_libraries(ignore_entities_ignorer PRIVATE ignore_entities_types ZZDDS::zzdds)

add_executable(ignore_entities_peer src/peer.c)
target_link_libraries(ignore_entities_peer PRIVATE ignore_entities_types ZZDDS::zzdds)

add_executable(ignore_entities_bystander src/bystander.c)
target_link_libraries(ignore_entities_bystander PRIVATE ignore_entities_types ZZDDS::zzdds)
