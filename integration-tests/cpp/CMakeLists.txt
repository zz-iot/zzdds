# Top-level aggregator for all C++ integration-tests apps. Mirrors
# examples/cpp/CMakeLists.txt. Add a new scenario by adding one
# add_subdirectory() line here; keep target names unique across scenarios in
# this file, since add_subdirectory() shares one flat target namespace.
cmake_minimum_required(VERSION 3.14)
project(zzdds_integration_tests_cpp)

add_subdirectory(coherent-sets)
add_subdirectory(delete-contained-entities)
add_subdirectory(sample-rejected-lost)
add_subdirectory(enable-defer)
