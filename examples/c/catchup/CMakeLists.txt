cmake_minimum_required(VERSION 3.14)
project(zzdds_catchup_c_example C)

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
    OUTPUT "${GENERATED_DIR}/catchup_sample.h" "${GENERATED_DIR}/catchup_sample_cdr.c"
    COMMAND "${ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${CATCHUP_IDL}"
    DEPENDS "${CATCHUP_IDL}"
    COMMENT "Generating HistoryEvent TypeSupport from catchup_sample.idl"
    VERBATIM
)
add_custom_target(generate_catchup_types DEPENDS "${GENERATED_DIR}/catchup_sample.h" "${GENERATED_DIR}/catchup_sample_cdr.c")

add_library(catchup_types STATIC "${GENERATED_DIR}/catchup_sample_cdr.c")
add_dependencies(catchup_types generate_catchup_types)
target_include_directories(catchup_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(catchup_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(catchup_pub src/publisher.c)
target_link_libraries(catchup_pub PRIVATE catchup_types ZZDDS::zzdds)

add_executable(catchup_sub src/subscriber.c)
target_link_libraries(catchup_sub PRIVATE catchup_types ZZDDS::zzdds)
