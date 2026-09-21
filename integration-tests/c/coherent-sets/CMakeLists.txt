cmake_minimum_required(VERSION 3.14)
project(zzdds_integration_coherent_sets_c C)

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

set(POSE_GROUP_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/pose_group.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/pose_group.h" "${GENERATED_DIR}/pose_group_cdr.c"
    COMMAND "${ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${POSE_GROUP_IDL}"
    DEPENDS "${POSE_GROUP_IDL}"
    COMMENT "Generating Position/Velocity TypeSupport from pose_group.idl"
    VERBATIM
)
add_custom_target(generate_coherent_sets_types DEPENDS "${GENERATED_DIR}/pose_group.h" "${GENERATED_DIR}/pose_group_cdr.c")

add_library(coherent_sets_types STATIC "${GENERATED_DIR}/pose_group_cdr.c")
add_dependencies(coherent_sets_types generate_coherent_sets_types)
target_include_directories(coherent_sets_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(coherent_sets_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(coherent_sets_pub src/publisher.c)
target_link_libraries(coherent_sets_pub PRIVATE coherent_sets_types ZZDDS::zzdds)

add_executable(coherent_sets_sub src/subscriber.c)
target_link_libraries(coherent_sets_sub PRIVATE coherent_sets_types ZZDDS::zzdds)
