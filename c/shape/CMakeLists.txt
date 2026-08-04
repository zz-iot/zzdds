cmake_minimum_required(VERSION 3.14)
project(zzdds_shape_c_example C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(ZZDDS REQUIRED)

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(SHAPE_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/shape.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/shape.h" "${GENERATED_DIR}/shape_cdr.c"
    COMMAND "${ZZDDS_ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${SHAPE_IDL}"
    DEPENDS "${SHAPE_IDL}"
    COMMENT "Generating ShapeType TypeSupport from shape.idl"
    VERBATIM
)
add_custom_target(generate_shape_types DEPENDS "${GENERATED_DIR}/shape.h" "${GENERATED_DIR}/shape_cdr.c")

add_library(shape_types STATIC "${GENERATED_DIR}/shape_cdr.c")
add_dependencies(shape_types generate_shape_types)
target_include_directories(shape_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(shape_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

# One binary, -P/-S selects publisher/subscriber mode -- matches
# zig/shape's shape_main (itself matching dds-rtps's srcZig/shape_main.zig,
# the authoritative CLI/behavior spec) and the dds-rtps interop harness
# convention of one binary path handed to both roles.
add_executable(shape_main src/shape_main.c)
target_link_libraries(shape_main PRIVATE shape_types ZZDDS::zzdds)
