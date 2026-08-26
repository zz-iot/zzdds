cmake_minimum_required(VERSION 3.16)
project(ovidds-zzdds CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Dependencies ──────────────────────────────────────────────────────────────

# cmake/ contains ZZDDSCodeGen.cmake and a fallback FindOpenCV.cmake (for
# Debian systems where the OpenCV packages omit cmake config files).
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

# Use the installed package-config file (produced by zig build -Dc-binding).
# ZZDDS_ROOT / $ENV{ZZDDS_ROOT} can be set to a non-standard install prefix.
if(DEFINED ZZDDS_ROOT)
    list(PREPEND CMAKE_PREFIX_PATH "${ZZDDS_ROOT}")
elseif(DEFINED ENV{ZZDDS_ROOT})
    list(PREPEND CMAKE_PREFIX_PATH "$ENV{ZZDDS_ROOT}")
endif()
find_package(ZZDDS CONFIG REQUIRED)
include(ZZDDSCodeGen)

find_package(OpenCV REQUIRED COMPONENTS core highgui imgproc objdetect videoio)

# ── ovidds IDL → generated C++ (shared among all targets) ────────────────────
#
# A small static library holds the generated CDR / DataWriter / DataReader
# implementation compiled once so that video_capture and video_roi_display do
# not each re-run zidl and re-compile the same generated code.
#
# dcps_impl.cpp and zzdds_impl.cpp (concrete entity Impl + listener bridge
# implementations) are compiled here too — they are generated sources shipped
# with the zzdds install.

add_library(ovidds_idl STATIC "")
zzdds_add_idl(ovidds_idl
    IDL_FILE ovidds.idl
    LANGUAGE cpp
    WRAPPERS
    OUTPUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/zzdds-gen"
)
target_sources(ovidds_idl PRIVATE
    "${ZZDDS_DCPS_IMPL_CPP}"
    "${ZZDDS_ZZDDS_IMPL_CPP}"
)
target_link_libraries(ovidds_idl PUBLIC
    ZZDDS::zzdds
    ZZDDS::zidl_cdr
)
# Propagate the generated include directory to consumers
target_include_directories(ovidds_idl PUBLIC
    "${CMAKE_CURRENT_BINARY_DIR}/zzdds-gen"
    "${CMAKE_CURRENT_SOURCE_DIR}"
)

# ── video_capture (publisher) ─────────────────────────────────────────────────

add_executable(video_capture video_capture.cpp)
target_compile_options(video_capture PRIVATE -Wall -Wextra)
target_link_libraries(video_capture PRIVATE
    ovidds_idl
    OpenCV::opencv_core
    OpenCV::opencv_highgui
    OpenCV::opencv_imgproc
    OpenCV::opencv_videoio
)

# ── video_roi_display (subscriber) ───────────────────────────────────────────

add_executable(video_roi_display video_roi_display.cpp)
target_compile_options(video_roi_display PRIVATE -Wall -Wextra)
target_link_libraries(video_roi_display PRIVATE
    ovidds_idl
    OpenCV::opencv_core
    OpenCV::opencv_highgui
    OpenCV::opencv_imgproc
)

# ── roi_generator (standalone face detector, no DDS) ─────────────────────────

add_executable(roi_generator roi_generator.cpp)
target_compile_options(roi_generator PRIVATE -Wall -Wextra)
target_link_libraries(roi_generator PRIVATE
    OpenCV::opencv_core
    OpenCV::opencv_highgui
    OpenCV::opencv_imgproc
    OpenCV::opencv_objdetect
    OpenCV::opencv_videoio
)

# ── Build instructions (printed as a status message) ─────────────────────────

message(STATUS "")
message(STATUS "Build steps:")
message(STATUS "  1. Build & install zzdds:")
message(STATUS "       zig build -Dc-binding -Dcpp-binding install --prefix \$ZZDDS_ROOT")
message(STATUS "  2. Configure this project:")
message(STATUS "       cmake -B build -DZZDDS_ROOT=\$ZZDDS_ROOT")
message(STATUS "  3. Build:")
message(STATUS "       cmake --build build")
message(STATUS "")
