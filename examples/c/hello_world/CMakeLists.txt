cmake_minimum_required(VERSION 3.14)
project(zzdds_hello_world_c_example C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(ZZDDS REQUIRED)

# ZZDDS_ZIDL_EXECUTABLE is whatever zidl the zzdds install you point
# CMAKE_PREFIX_PATH at happened to bundle -- zzdds's own build.zig.zon pins
# zidl to a tagged release URL, not a local path, so it can lag behind a
# zidl checkout with unreleased fixes (e.g. keyless-struct
# --generate-zzdds-wrappers support). Override with
# -DZIDL_EXECUTABLE=/path/to/local/zidl/zig-out/bin/zidl to build against a
# newer local zidl without needing to touch zzdds's own dependency pin.
if(NOT DEFINED ZIDL_EXECUTABLE)
    set(ZIDL_EXECUTABLE "${ZZDDS_ZIDL_EXECUTABLE}")
endif()

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(HELLO_WORLD_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/hello_world.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/hello_world.h" "${GENERATED_DIR}/hello_world_cdr.c"
    COMMAND "${ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${HELLO_WORLD_IDL}"
    DEPENDS "${HELLO_WORLD_IDL}"
    COMMENT "Generating HelloWorld TypeSupport from hello_world.idl"
    VERBATIM
)
add_custom_target(generate_hello_world_types DEPENDS "${GENERATED_DIR}/hello_world.h" "${GENERATED_DIR}/hello_world_cdr.c")

add_library(hello_world_types STATIC "${GENERATED_DIR}/hello_world_cdr.c")
add_dependencies(hello_world_types generate_hello_world_types)
target_include_directories(hello_world_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(hello_world_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

# Distinct target names from shape/custom-allocator's publisher/subscriber,
# per docs/design/shape-reference-app.md's naming convention.
add_executable(hello_world_pub src/publisher.c)
target_link_libraries(hello_world_pub PRIVATE hello_world_types ZZDDS::zzdds)

add_executable(hello_world_sub src/subscriber.c)
target_link_libraries(hello_world_sub PRIVATE hello_world_types ZZDDS::zzdds)
