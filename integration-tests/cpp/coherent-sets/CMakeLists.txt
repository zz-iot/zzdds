cmake_minimum_required(VERSION 3.14)
project(zzdds_integration_coherent_sets_cpp CXX C)

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

set(POSE_GROUP_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/pose_group.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/pose_group.hpp" "${GENERATED_DIR}/pose_group_cdr.cpp"
    COMMAND "${ZIDL_EXECUTABLE}" -b cpp --generate-interfaces --cpp-pmr-containers --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${POSE_GROUP_IDL}"
    DEPENDS "${POSE_GROUP_IDL}"
    COMMENT "Generating Position/Velocity C++ TypeSupport from pose_group.idl"
    VERBATIM
)
add_custom_target(generate_coherent_sets_types DEPENDS "${GENERATED_DIR}/pose_group.hpp" "${GENERATED_DIR}/pose_group_cdr.cpp")

add_library(coherent_sets_dcps_impl STATIC
    "${ZZDDS_DCPS_IMPL_CPP}"
    "${ZZDDS_ZZDDS_IMPL_CPP}"
    "${GENERATED_DIR}/pose_group_cdr.cpp"
)
add_dependencies(coherent_sets_dcps_impl generate_coherent_sets_types)
target_include_directories(coherent_sets_dcps_impl PUBLIC "${GENERATED_DIR}")
target_link_libraries(coherent_sets_dcps_impl PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(coherent_sets_pub src/publisher.cpp)
target_link_libraries(coherent_sets_pub PRIVATE coherent_sets_dcps_impl ZZDDS::zzdds)

add_executable(coherent_sets_sub src/subscriber.cpp)
target_link_libraries(coherent_sets_sub PRIVATE coherent_sets_dcps_impl ZZDDS::zzdds)
