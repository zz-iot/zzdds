# Top-level aggregator for all C examples: builds every example below with a
# single CMake invocation, e.g.
#
#   cmake -DCMAKE_PREFIX_PATH=/path/to/zzdds/zig-out -B build -S c
#   cmake --build build
#
# Each example directory is still a complete, independent CMake project on
# its own (see its own CMakeLists.txt / README for building it in isolation).
# Add a new example by adding one add_subdirectory() line here; keep target
# names unique across examples in this file, since add_subdirectory() shares
# one flat target namespace.
cmake_minimum_required(VERSION 3.14)
project(zzdds_c_examples)

add_subdirectory(catchup)
add_subdirectory(custom-allocator)
add_subdirectory(discovery)
add_subdirectory(hello_world)
add_subdirectory(participant-config)
add_subdirectory(presence)
add_subdirectory(registry)
add_subdirectory(shape)
add_subdirectory(waitset)
