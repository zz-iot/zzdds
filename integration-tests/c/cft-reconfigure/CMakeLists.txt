cmake_minimum_required(VERSION 3.14)
project(zzdds_integration_cft_reconfigure_c C)

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

set(CFT_EVENT_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/cft_event.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/cft_event.h" "${GENERATED_DIR}/cft_event_cdr.c"
    COMMAND "${ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${CFT_EVENT_IDL}"
    DEPENDS "${CFT_EVENT_IDL}"
    COMMENT "Generating CftEvent TypeSupport from cft_event.idl"
    VERBATIM
)
add_custom_target(generate_cft_reconfigure_types DEPENDS "${GENERATED_DIR}/cft_event.h" "${GENERATED_DIR}/cft_event_cdr.c")

add_library(cft_reconfigure_types STATIC "${GENERATED_DIR}/cft_event_cdr.c")
add_dependencies(cft_reconfigure_types generate_cft_reconfigure_types)
target_include_directories(cft_reconfigure_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(cft_reconfigure_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(cft_reconfigure_publisher src/publisher.c)
target_link_libraries(cft_reconfigure_publisher PRIVATE cft_reconfigure_types ZZDDS::zzdds)

add_executable(cft_reconfigure_subscriber src/subscriber.c)
target_link_libraries(cft_reconfigure_subscriber PRIVATE cft_reconfigure_types ZZDDS::zzdds)
