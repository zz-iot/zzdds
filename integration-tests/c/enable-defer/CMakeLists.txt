cmake_minimum_required(VERSION 3.14)
project(zzdds_integration_enable_defer_c C)

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

# See examples/c/raw-loan/CMakeLists.txt's matching comment: zzdds's own
# build.zig.zon pins zidl to a tagged release URL, which can lag behind a
# zidl checkout with unreleased fixes. Override with -DZIDL_EXECUTABLE=...
# to build against a newer local zidl.
if(NOT DEFINED ZIDL_EXECUTABLE)
    set(ZIDL_EXECUTABLE "${ZZDDS_ZIDL_EXECUTABLE}")
endif()

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(CONFIG_EVENT_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/config_event.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/config_event.h" "${GENERATED_DIR}/config_event_cdr.c"
    COMMAND "${ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${CONFIG_EVENT_IDL}"
    DEPENDS "${CONFIG_EVENT_IDL}"
    COMMENT "Generating ConfigEvent TypeSupport from config_event.idl"
    VERBATIM
)
add_custom_target(generate_enable_defer_types DEPENDS "${GENERATED_DIR}/config_event.h" "${GENERATED_DIR}/config_event_cdr.c")

add_library(enable_defer_types STATIC "${GENERATED_DIR}/config_event_cdr.c")
add_dependencies(enable_defer_types generate_enable_defer_types)
target_include_directories(enable_defer_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(enable_defer_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(enable_defer_configurer src/configurer.c)
target_link_libraries(enable_defer_configurer PRIVATE enable_defer_types ZZDDS::zzdds)

add_executable(enable_defer_peer src/peer.c)
target_link_libraries(enable_defer_peer PRIVATE enable_defer_types ZZDDS::zzdds)
