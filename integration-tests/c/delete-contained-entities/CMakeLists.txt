cmake_minimum_required(VERSION 3.14)
project(zzdds_integration_delete_contained_entities_c C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(ZZDDS REQUIRED)

# See examples/c/raw-loan/CMakeLists.txt's matching comment: zzdds's own
# build.zig.zon pins zidl to a tagged release URL, which can lag behind a
# zidl checkout with unreleased fixes. Override with -DZIDL_EXECUTABLE=...
# to build against a newer local zidl.
if(NOT DEFINED ZIDL_EXECUTABLE)
    set(ZIDL_EXECUTABLE "${ZZDDS_ZIDL_EXECUTABLE}")
endif()

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(SESSION_EVENT_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/session_event.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/session_event.h" "${GENERATED_DIR}/session_event_cdr.c"
    COMMAND "${ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${SESSION_EVENT_IDL}"
    DEPENDS "${SESSION_EVENT_IDL}"
    COMMENT "Generating SessionEvent TypeSupport from session_event.idl"
    VERBATIM
)
add_custom_target(generate_delete_contained_entities_types DEPENDS "${GENERATED_DIR}/session_event.h" "${GENERATED_DIR}/session_event_cdr.c")

add_library(delete_contained_entities_types STATIC "${GENERATED_DIR}/session_event_cdr.c")
add_dependencies(delete_contained_entities_types generate_delete_contained_entities_types)
target_include_directories(delete_contained_entities_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(delete_contained_entities_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(delete_contained_entities_session src/session.c)
target_link_libraries(delete_contained_entities_session PRIVATE delete_contained_entities_types ZZDDS::zzdds)

add_executable(delete_contained_entities_peer src/peer.c)
target_link_libraries(delete_contained_entities_peer PRIVATE delete_contained_entities_types ZZDDS::zzdds)
