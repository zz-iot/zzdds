cmake_minimum_required(VERSION 3.14)
project(zzdds_integration_wait_for_historical_data_c C)

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

set(HISTORY_EVENT_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/history_event.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/history_event.h" "${GENERATED_DIR}/history_event_cdr.c"
    COMMAND "${ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${HISTORY_EVENT_IDL}"
    DEPENDS "${HISTORY_EVENT_IDL}"
    COMMENT "Generating HistoryEvent TypeSupport from history_event.idl"
    VERBATIM
)
add_custom_target(generate_wait_for_historical_data_types DEPENDS "${GENERATED_DIR}/history_event.h" "${GENERATED_DIR}/history_event_cdr.c")

add_library(wait_for_historical_data_types STATIC "${GENERATED_DIR}/history_event_cdr.c")
add_dependencies(wait_for_historical_data_types generate_wait_for_historical_data_types)
target_include_directories(wait_for_historical_data_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(wait_for_historical_data_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(wait_for_historical_data_publisher src/publisher.c)
target_link_libraries(wait_for_historical_data_publisher PRIVATE wait_for_historical_data_types ZZDDS::zzdds)

add_executable(wait_for_historical_data_subscriber src/subscriber.c)
target_link_libraries(wait_for_historical_data_subscriber PRIVATE wait_for_historical_data_types ZZDDS::zzdds)
