cmake_minimum_required(VERSION 3.14)
project(zzdds_presence_c_example C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(ZZDDS REQUIRED)

# See c/hello_world/CMakeLists.txt's matching comment: zzdds's own
# build.zig.zon pins zidl to a tagged release URL, which can lag behind a
# zidl checkout with unreleased fixes. Override with -DZIDL_EXECUTABLE=...
# to build against a newer local zidl.
if(NOT DEFINED ZIDL_EXECUTABLE)
    set(ZIDL_EXECUTABLE "${ZZDDS_ZIDL_EXECUTABLE}")
endif()

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(PRESENCE_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/presence_sample.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/presence_sample.h" "${GENERATED_DIR}/presence_sample_cdr.c"
    COMMAND "${ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${PRESENCE_IDL}"
    DEPENDS "${PRESENCE_IDL}"
    COMMENT "Generating PresenceBeacon TypeSupport from presence_sample.idl"
    VERBATIM
)
add_custom_target(generate_presence_types DEPENDS "${GENERATED_DIR}/presence_sample.h" "${GENERATED_DIR}/presence_sample_cdr.c")

add_library(presence_types STATIC "${GENERATED_DIR}/presence_sample_cdr.c")
add_dependencies(presence_types generate_presence_types)
target_include_directories(presence_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(presence_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(presence_pub src/publisher.c)
target_link_libraries(presence_pub PRIVATE presence_types ZZDDS::zzdds)

add_executable(presence_sub src/subscriber.c)
target_link_libraries(presence_sub PRIVATE presence_types ZZDDS::zzdds)
