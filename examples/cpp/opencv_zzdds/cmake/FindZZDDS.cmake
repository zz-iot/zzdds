# FindZZDDS.cmake
#
# Locates a zzdds installation produced by `zig build -Dc-binding -Dcpp-binding install`.
#
# The install prefix is resolved from (in order):
#   1. CMake variable ZZDDS_ROOT
#   2. Environment variable ZZDDS_ROOT
#   3. Standard system paths (/usr/local, /usr, …)
#
# After a successful find_package(ZZDDS) call the following are available:
#
#   ZZDDS_FOUND            — TRUE if all required components were located
#   ZZDDS_INCLUDE_DIRS     — Directories containing dcps.h, zzdds_c.h, zidl_cdr.h
#   ZZDDS_LIBRARIES        — Imported link libraries (libzzdds.so / zzdds.dll)
#   ZZDDS_ZIDL_EXECUTABLE  — Path to the zidl IDL compiler (may be NOTFOUND)
#   ZZDDS::zzdds           — Imported target (preferred over raw vars)
#
# Usage:
#   find_package(ZZDDS REQUIRED)
#   target_link_libraries(my_app PRIVATE ZZDDS::zzdds)
#
# For IDL code generation see cmake/ZZDDSCodeGen.cmake.

cmake_minimum_required(VERSION 3.16)

# ── Resolve search root ───────────────────────────────────────────────────────

set(_zzdds_root "")
if(DEFINED ZZDDS_ROOT)
    set(_zzdds_root "${ZZDDS_ROOT}")
elseif(DEFINED ENV{ZZDDS_ROOT})
    set(_zzdds_root "$ENV{ZZDDS_ROOT}")
endif()

# ── Find headers ──────────────────────────────────────────────────────────────

find_path(ZZDDS_INCLUDE_DIR
    NAMES zzdds_c.h
    HINTS "${_zzdds_root}/include"
    PATH_SUFFIXES include
    DOC "Directory containing zzdds_c.h (zzdds C ABI header)"
)

# ── Find runtime library ──────────────────────────────────────────────────────

find_library(ZZDDS_LIBRARY
    NAMES zzdds
    HINTS "${_zzdds_root}/lib" "${_zzdds_root}/lib64"
    PATH_SUFFIXES lib lib64
    DOC "zzdds shared library"
)

# ── Find zidl code generator (optional but highly recommended) ────────────────

find_program(ZZDDS_ZIDL_EXECUTABLE
    NAMES zidl
    HINTS "${_zzdds_root}/bin"
    DOC "zidl IDL compiler"
)

# ── Standard result handling ──────────────────────────────────────────────────

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(ZZDDS
    REQUIRED_VARS ZZDDS_INCLUDE_DIR ZZDDS_LIBRARY
    FAIL_MESSAGE  "Could not find zzdds. Set ZZDDS_ROOT to the zig-out install prefix."
)

# ── Expose imported target ────────────────────────────────────────────────────

if(ZZDDS_FOUND AND NOT TARGET ZZDDS::zzdds)
    add_library(ZZDDS::zzdds SHARED IMPORTED)
    set_target_properties(ZZDDS::zzdds PROPERTIES
        IMPORTED_LOCATION             "${ZZDDS_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "${ZZDDS_INCLUDE_DIR}"
    )
endif()

# ── Convenience variables ─────────────────────────────────────────────────────

set(ZZDDS_INCLUDE_DIRS "${ZZDDS_INCLUDE_DIR}")
set(ZZDDS_LIBRARIES    "${ZZDDS_LIBRARY}")

if(ZZDDS_ZIDL_EXECUTABLE)
    message(STATUS "Found zidl: ${ZZDDS_ZIDL_EXECUTABLE}")
else()
    message(STATUS "zidl not found — IDL code generation will require pre-generated sources")
endif()

mark_as_advanced(ZZDDS_INCLUDE_DIR ZZDDS_LIBRARY ZZDDS_ZIDL_EXECUTABLE)
