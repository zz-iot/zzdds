cmake_minimum_required(VERSION 3.14)
project(zzdds_registry_cpp_example CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
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
    OUTPUT "${GENERATED_DIR}/registry_sample.hpp" "${GENERATED_DIR}/registry_sample_cdr.cpp"
    COMMAND "${ZIDL_EXECUTABLE}" -b cpp --generate-interfaces --cpp-pmr-containers --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${REGISTRY_IDL}"
    DEPENDS "${REGISTRY_IDL}"
    COMMENT "Generating SensorReading C++ TypeSupport from registry_sample.idl"
    VERBATIM
)
add_custom_target(generate_registry_types DEPENDS "${GENERATED_DIR}/registry_sample.hpp" "${GENERATED_DIR}/registry_sample_cdr.cpp")

add_library(registry_dcps_impl STATIC
    "${ZZDDS_DCPS_IMPL_CPP}"
    "${ZZDDS_ZZDDS_IMPL_CPP}"
    "${GENERATED_DIR}/registry_sample_cdr.cpp"
)
add_dependencies(registry_dcps_impl generate_registry_types)
target_include_directories(registry_dcps_impl PUBLIC "${GENERATED_DIR}")
target_link_libraries(registry_dcps_impl PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(registry_pub src/publisher.cpp)
target_link_libraries(registry_pub PRIVATE registry_dcps_impl ZZDDS::zzdds)

add_executable(registry_sub src/subscriber.cpp)
target_link_libraries(registry_sub PRIVATE registry_dcps_impl ZZDDS::zzdds)
