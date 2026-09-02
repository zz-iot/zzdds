# Minimal downstream CMake project that consumes a relocated zzdds bundle via
# find_package(ZZDDS). Driven by scripts/verify_release_bundle.py:
#
#   cmake -S . -B build -DCMAKE_PREFIX_PATH=<extracted-bundle-prefix>
#   cmake --build build      # skipped with --configure-only (Windows)
#   ./build/zzdds_bundle_cmake_consumer
#
# It asserts the generated lib/cmake/ZZDDS/zzdds-config.cmake defines
# everything a real consumer (see examples/{c,cpp}/hello_world) depends on,
# then compiles/links/runs the shared consumer.c against the imported targets.
cmake_minimum_required(VERSION 3.14)
project(zzdds_bundle_cmake_consumer C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(ZZDDS REQUIRED)

foreach(_target ZZDDS::zzdds ZZDDS::zidl_cdr)
    if(NOT TARGET ${_target})
        message(FATAL_ERROR "ZZDDS package config did not define imported target ${_target}")
    endif()
endforeach()

if(NOT DEFINED ZZDDS_ZIDL_EXECUTABLE OR NOT EXISTS "${ZZDDS_ZIDL_EXECUTABLE}")
    message(FATAL_ERROR "ZZDDS_ZIDL_EXECUTABLE missing or does not exist: '${ZZDDS_ZIDL_EXECUTABLE}'")
endif()

foreach(_var ZZDDS_DCPS_IMPL_CPP ZZDDS_ZZDDS_IMPL_CPP)
    if(NOT DEFINED ${_var} OR NOT EXISTS "${${_var}}")
        message(FATAL_ERROR "${_var} missing or does not exist: '${${_var}}'")
    endif()
endforeach()

add_executable(zzdds_bundle_cmake_consumer "${CMAKE_CURRENT_SOURCE_DIR}/../consumer.c")
target_link_libraries(zzdds_bundle_cmake_consumer PRIVATE ZZDDS::zzdds ZZDDS::zidl_cdr)
