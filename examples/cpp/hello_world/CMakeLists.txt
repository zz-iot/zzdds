cmake_minimum_required(VERSION 3.14)
project(zzdds_hello_world_cpp_example CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(ZZDDS REQUIRED)

# See c/hello_world/CMakeLists.txt's matching comment: zzdds's own
# build.zig.zon pins zidl to a tagged release URL, which can lag behind a
# zidl checkout with unreleased fixes (keyless-struct
# --generate-zzdds-wrappers support, needed here since HelloWorld is
# deliberately keyless). Override with -DZIDL_EXECUTABLE=... to build
# against a newer local zidl.
if(NOT DEFINED ZIDL_EXECUTABLE)
    set(ZIDL_EXECUTABLE "${ZZDDS_ZIDL_EXECUTABLE}")
endif()

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(HELLO_WORLD_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/hello_world.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/hello_world.hpp" "${GENERATED_DIR}/hello_world_cdr.cpp"
    COMMAND "${ZIDL_EXECUTABLE}" -b cpp --generate-interfaces --cpp-pmr-containers --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${HELLO_WORLD_IDL}"
    DEPENDS "${HELLO_WORLD_IDL}"
    COMMENT "Generating HelloWorld C++ TypeSupport from hello_world.idl"
    VERBATIM
)
add_custom_target(generate_hello_world_types DEPENDS "${GENERATED_DIR}/hello_world.hpp" "${GENERATED_DIR}/hello_world_cdr.cpp")

# zzdds's own pre-generated DCPS entity implementation, compiled directly by
# consumers -- see cpp/custom-allocator/CMakeLists.txt's matching comment
# ("three-artifact model": shared lib + these two generated .cpp files + headers).
add_library(hello_world_dcps_impl STATIC
    "${ZZDDS_DCPS_IMPL_CPP}"
    "${ZZDDS_ZZDDS_IMPL_CPP}"
    "${GENERATED_DIR}/hello_world_cdr.cpp"
)
add_dependencies(hello_world_dcps_impl generate_hello_world_types)
target_include_directories(hello_world_dcps_impl PUBLIC "${GENERATED_DIR}")
target_link_libraries(hello_world_dcps_impl PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(hello_world_pub src/publisher.cpp)
target_link_libraries(hello_world_pub PRIVATE hello_world_dcps_impl ZZDDS::zzdds)

add_executable(hello_world_sub src/subscriber.cpp)
target_link_libraries(hello_world_sub PRIVATE hello_world_dcps_impl ZZDDS::zzdds)
