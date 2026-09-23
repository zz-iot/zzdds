# Top-level aggregator for all C integration-tests apps: builds every
# scenario below with a single CMake invocation, e.g.
#
#   cmake -DCMAKE_PREFIX_PATH=/path/to/zzdds/zig-out -B build -S c
#   cmake --build build
#
# Mirrors examples/c/CMakeLists.txt. Add a new scenario by adding one
# add_subdirectory() line here; keep target names unique across scenarios in
# this file, since add_subdirectory() shares one flat target namespace.
cmake_minimum_required(VERSION 3.14)
project(zzdds_integration_tests_c)

add_subdirectory(coherent-sets)
add_subdirectory(delete-contained-entities)
add_subdirectory(sample-rejected-lost)
add_subdirectory(enable-defer)
add_subdirectory(wait-for-historical-data)
add_subdirectory(ignore-entities)
add_subdirectory(cft-reconfigure)
add_subdirectory(source-timestamp)
add_subdirectory(liveliness-lost)
