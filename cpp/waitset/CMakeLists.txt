cmake_minimum_required(VERSION 3.14)
project(zzdds_waitset_cpp_example CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Off by default -- this example's own watchdog-thread + WaitSet.wait()
# combination is exactly the kind of real concurrency this whole example was
# built to exercise (see docs/design/waitset-reference-app.md), so being able
# to build it under ThreadSanitizer matters more here than for most other
# examples in this repo. Requires zzdds itself to also be built with
# -Dsanitize-thread=true against the SAME CMAKE_PREFIX_PATH -- mixing a
# TSAN'd example with a non-TSAN'd libzzdds (or vice versa) doesn't reliably
# detect races across that boundary.
option(WAITSET_SANITIZE_THREAD "Build with -fsanitize=thread (requires zzdds built with -Dsanitize-thread=true)" OFF)
if(WAITSET_SANITIZE_THREAD)
    add_compile_options(-fsanitize=thread -g -O1)
    add_link_options(-fsanitize=thread)
endif()

find_package(ZZDDS REQUIRED)

# See c/hello_world/CMakeLists.txt's matching comment.
if(NOT DEFINED ZIDL_EXECUTABLE)
    set(ZIDL_EXECUTABLE "${ZZDDS_ZIDL_EXECUTABLE}")
endif()

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(WAITSET_SAMPLE_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/waitset_sample.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/waitset_sample.hpp" "${GENERATED_DIR}/waitset_sample_cdr.cpp"
    COMMAND "${ZIDL_EXECUTABLE}" -b cpp --generate-interfaces --cpp-pmr-containers --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${WAITSET_SAMPLE_IDL}"
    DEPENDS "${WAITSET_SAMPLE_IDL}"
    COMMENT "Generating WaitsetSample C++ TypeSupport from waitset_sample.idl"
    VERBATIM
)
add_custom_target(generate_waitset_sample_types DEPENDS "${GENERATED_DIR}/waitset_sample.hpp" "${GENERATED_DIR}/waitset_sample_cdr.cpp")

# zzdds's own pre-generated DCPS entity implementation, compiled directly by
# consumers -- see cpp/hello_world/CMakeLists.txt's matching comment
# ("three-artifact model": shared lib + these two generated .cpp files + headers).
add_library(dcps_impl STATIC
    "${ZZDDS_DCPS_IMPL_CPP}"
    "${ZZDDS_ZZDDS_IMPL_CPP}"
    "${GENERATED_DIR}/waitset_sample_cdr.cpp"
)
add_dependencies(dcps_impl generate_waitset_sample_types)
target_include_directories(dcps_impl PUBLIC "${GENERATED_DIR}")
target_link_libraries(dcps_impl PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

find_package(Threads REQUIRED)

add_executable(waitset_pub src/publisher.cpp)
target_link_libraries(waitset_pub PRIVATE dcps_impl ZZDDS::zzdds Threads::Threads)

add_executable(waitset_sub src/subscriber.cpp)
target_link_libraries(waitset_sub PRIVATE dcps_impl ZZDDS::zzdds Threads::Threads)
