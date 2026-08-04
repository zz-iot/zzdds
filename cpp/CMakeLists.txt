# Top-level aggregator for all C++ examples: builds every example below with
# a single CMake invocation, e.g.
#
#   cmake -DCMAKE_PREFIX_PATH=/path/to/zzdds/zig-out -B build -S cpp
#   cmake --build build
#
# Each example directory is still a complete, independent CMake project on
# its own (see its own CMakeLists.txt / README for building it in isolation).
# opencv_zzdds additionally requires OpenCV (find_package(OpenCV) inside its
# own CMakeLists.txt) — that dependency stays scoped to its subdirectory and
# is not required to build the other examples here.
#
# Add a new example by adding one add_subdirectory() line here; keep target
# names unique across examples in this file, since add_subdirectory() shares
# one flat target namespace.
cmake_minimum_required(VERSION 3.16)
project(zzdds_cpp_examples)

add_subdirectory(custom-allocator)
add_subdirectory(shape)

# opencv_zzdds additionally needs OpenCV, which isn't available on every
# build machine (e.g. CI images without libopencv-dev). Probe for it here,
# using opencv_zzdds's own fallback finder module, so a missing OpenCV
# degrades this aggregator to "build everything except opencv_zzdds" instead
# of failing the whole configure step before anything gets built.
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/opencv_zzdds/cmake")
find_package(OpenCV QUIET OPTIONAL_COMPONENTS core highgui imgproc objdetect videoio)
if(OpenCV_FOUND)
    add_subdirectory(opencv_zzdds)
else()
    message(STATUS "OpenCV not found — skipping opencv_zzdds example (install libopencv-dev to include it)")
endif()
