cmake_minimum_required(VERSION 3.14)
project(zzdds_raw_loan_cpp_example CXX C)

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

set(RAW_LOAN_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/loaned_ping.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/loaned_ping.hpp" "${GENERATED_DIR}/loaned_ping_cdr.cpp"
    COMMAND "${ZIDL_EXECUTABLE}" -b cpp --generate-interfaces --cpp-pmr-containers --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${RAW_LOAN_IDL}"
    DEPENDS "${RAW_LOAN_IDL}"
    COMMENT "Generating LoanedPing C++ TypeSupport from loaned_ping.idl"
    VERBATIM
)
add_custom_target(generate_raw_loan_types DEPENDS "${GENERATED_DIR}/loaned_ping.hpp" "${GENERATED_DIR}/loaned_ping_cdr.cpp")

add_library(raw_loan_dcps_impl STATIC
    "${ZZDDS_DCPS_IMPL_CPP}"
    "${ZZDDS_ZZDDS_IMPL_CPP}"
    "${GENERATED_DIR}/loaned_ping_cdr.cpp"
)
add_dependencies(raw_loan_dcps_impl generate_raw_loan_types)
target_include_directories(raw_loan_dcps_impl PUBLIC "${GENERATED_DIR}")
target_link_libraries(raw_loan_dcps_impl PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(raw_loan_pub src/publisher.cpp)
target_link_libraries(raw_loan_pub PRIVATE raw_loan_dcps_impl ZZDDS::zzdds)

add_executable(raw_loan_sub src/subscriber.cpp)
target_link_libraries(raw_loan_sub PRIVATE raw_loan_dcps_impl ZZDDS::zzdds)
