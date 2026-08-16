cmake_minimum_required(VERSION 3.14)
project(zzdds_shape_cpp_example CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# See cpp/waitset/CMakeLists.txt's matching option for the full rationale.
# Real concurrency here: timer thread + UDP receive thread + listener
# dispatch vs. the main loop.
option(SHAPE_SANITIZE_THREAD "Build with -fsanitize=thread (requires zzdds built with -Dsanitize-thread=true)" OFF)
if(SHAPE_SANITIZE_THREAD)
    add_compile_options(-fsanitize=thread -g -O1)
endif()

find_package(ZZDDS REQUIRED)

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(SHAPE_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/shape.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/shape.hpp" "${GENERATED_DIR}/shape_cdr.cpp"
    COMMAND "${ZZDDS_ZIDL_EXECUTABLE}" -b cpp --generate-interfaces --cpp-pmr-containers --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${SHAPE_IDL}"
    DEPENDS "${SHAPE_IDL}"
    COMMENT "Generating ShapeType C++ TypeSupport from shape.idl"
    VERBATIM
)
add_custom_target(generate_shape_types DEPENDS "${GENERATED_DIR}/shape.hpp" "${GENERATED_DIR}/shape_cdr.cpp")

# zzdds's own pre-generated DCPS entity implementation (DomainParticipant,
# Topic, Publisher/Subscriber, DataWriter/DataReader, ...) -- compiled by
# consumers directly, not baked into libzzdds.so (same three-artifact model
# cpp/custom-allocator uses: shared lib + these two generated .cpp files +
# headers).
add_library(shape_dcps_impl STATIC
    "${ZZDDS_DCPS_IMPL_CPP}"
    "${ZZDDS_ZZDDS_IMPL_CPP}"
    "${GENERATED_DIR}/shape_cdr.cpp"
)
add_dependencies(shape_dcps_impl generate_shape_types)
target_include_directories(shape_dcps_impl PUBLIC "${GENERATED_DIR}")
target_link_libraries(shape_dcps_impl PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

# One binary, -P/-S selects publisher/subscriber mode -- see c/shape and
# zig/shape for why (matches the dds-rtps interop harness convention of one
# binary path for both roles).
add_executable(shape_main src/shape_main.cpp)
target_link_libraries(shape_main PRIVATE shape_dcps_impl ZZDDS::zzdds)
