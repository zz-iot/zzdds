cmake_minimum_required(VERSION 3.14)
project(zzdds_waitset_c_example C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# See cpp/waitset/CMakeLists.txt's matching option for the full rationale.
option(WAITSET_SANITIZE_THREAD "Build with -fsanitize=thread (requires zzdds built with -Dsanitize-thread=true)" OFF)
if(WAITSET_SANITIZE_THREAD)
    add_compile_options(-fsanitize=thread -g -O1)
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
    OUTPUT "${GENERATED_DIR}/waitset_sample.h" "${GENERATED_DIR}/waitset_sample_cdr.c"
    COMMAND "${ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${WAITSET_SAMPLE_IDL}"
    DEPENDS "${WAITSET_SAMPLE_IDL}"
    COMMENT "Generating WaitsetSample TypeSupport from waitset_sample.idl"
    VERBATIM
)
add_custom_target(generate_waitset_sample_types DEPENDS "${GENERATED_DIR}/waitset_sample.h" "${GENERATED_DIR}/waitset_sample_cdr.c")

add_library(waitset_sample_types STATIC "${GENERATED_DIR}/waitset_sample_cdr.c")
add_dependencies(waitset_sample_types generate_waitset_sample_types)
target_include_directories(waitset_sample_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(waitset_sample_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

find_package(Threads REQUIRED)

add_executable(waitset_pub src/publisher.c)
target_link_libraries(waitset_pub PRIVATE waitset_sample_types ZZDDS::zzdds Threads::Threads)

add_executable(waitset_sub src/subscriber.c)
target_link_libraries(waitset_sub PRIVATE waitset_sample_types ZZDDS::zzdds Threads::Threads)
