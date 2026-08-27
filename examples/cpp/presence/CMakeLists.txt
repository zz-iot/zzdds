cmake_minimum_required(VERSION 3.14)
project(zzdds_presence_cpp_example CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
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
    OUTPUT "${GENERATED_DIR}/presence_sample.hpp" "${GENERATED_DIR}/presence_sample_cdr.cpp"
    COMMAND "${ZIDL_EXECUTABLE}" -b cpp --generate-interfaces --cpp-pmr-containers --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${PRESENCE_IDL}"
    DEPENDS "${PRESENCE_IDL}"
    COMMENT "Generating PresenceBeacon C++ TypeSupport from presence_sample.idl"
    VERBATIM
)
add_custom_target(generate_presence_types DEPENDS "${GENERATED_DIR}/presence_sample.hpp" "${GENERATED_DIR}/presence_sample_cdr.cpp")

# zzdds's own pre-generated DCPS entity implementation, compiled directly by
# consumers -- see cpp/custom-allocator/CMakeLists.txt's matching comment
# ("three-artifact model": shared lib + these two generated .cpp files + headers).
add_library(presence_dcps_impl STATIC
    "${ZZDDS_DCPS_IMPL_CPP}"
    "${ZZDDS_ZZDDS_IMPL_CPP}"
    "${GENERATED_DIR}/presence_sample_cdr.cpp"
)
add_dependencies(presence_dcps_impl generate_presence_types)
target_include_directories(presence_dcps_impl PUBLIC "${GENERATED_DIR}")
target_link_libraries(presence_dcps_impl PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(presence_pub src/publisher.cpp)
target_link_libraries(presence_pub PRIVATE presence_dcps_impl ZZDDS::zzdds)

add_executable(presence_sub src/subscriber.cpp)
target_link_libraries(presence_sub PRIVATE presence_dcps_impl ZZDDS::zzdds)
