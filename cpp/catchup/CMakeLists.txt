cmake_minimum_required(VERSION 3.14)
project(zzdds_catchup_cpp_example CXX C)

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

set(CATCHUP_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/catchup_sample.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/catchup_sample.hpp" "${GENERATED_DIR}/catchup_sample_cdr.cpp"
    COMMAND "${ZIDL_EXECUTABLE}" -b cpp --generate-interfaces --cpp-pmr-containers --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${CATCHUP_IDL}"
    DEPENDS "${CATCHUP_IDL}"
    COMMENT "Generating HistoryEvent C++ TypeSupport from catchup_sample.idl"
    VERBATIM
)
add_custom_target(generate_catchup_types DEPENDS "${GENERATED_DIR}/catchup_sample.hpp" "${GENERATED_DIR}/catchup_sample_cdr.cpp")

add_library(dcps_impl STATIC
    "${ZZDDS_DCPS_IMPL_CPP}"
    "${ZZDDS_ZZDDS_IMPL_CPP}"
    "${GENERATED_DIR}/catchup_sample_cdr.cpp"
)
add_dependencies(dcps_impl generate_catchup_types)
target_include_directories(dcps_impl PUBLIC "${GENERATED_DIR}")
target_link_libraries(dcps_impl PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(catchup_pub src/publisher.cpp)
target_link_libraries(catchup_pub PRIVATE dcps_impl ZZDDS::zzdds)

add_executable(catchup_sub src/subscriber.cpp)
target_link_libraries(catchup_sub PRIVATE dcps_impl ZZDDS::zzdds)
