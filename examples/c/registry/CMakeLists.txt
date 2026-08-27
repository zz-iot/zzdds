cmake_minimum_required(VERSION 3.14)
project(zzdds_registry_c_example C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(ZZDDS REQUIRED)

if(NOT DEFINED ZIDL_EXECUTABLE)
    set(ZIDL_EXECUTABLE "${ZZDDS_ZIDL_EXECUTABLE}")
endif()

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(REGISTRY_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/registry_sample.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/registry_sample.h" "${GENERATED_DIR}/registry_sample_cdr.c"
    COMMAND "${ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${REGISTRY_IDL}"
    DEPENDS "${REGISTRY_IDL}"
    COMMENT "Generating SensorReading TypeSupport from registry_sample.idl"
    VERBATIM
)
add_custom_target(generate_registry_types DEPENDS "${GENERATED_DIR}/registry_sample.h" "${GENERATED_DIR}/registry_sample_cdr.c")

add_library(registry_types STATIC "${GENERATED_DIR}/registry_sample_cdr.c")
add_dependencies(registry_types generate_registry_types)
target_include_directories(registry_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(registry_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(registry_pub src/publisher.c)
target_link_libraries(registry_pub PRIVATE registry_types ZZDDS::zzdds)

add_executable(registry_sub src/subscriber.c)
target_link_libraries(registry_sub PRIVATE registry_types ZZDDS::zzdds)
