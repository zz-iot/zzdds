cmake_minimum_required(VERSION 3.14)
project(zzdds_raw_loan_c_example C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

find_package(ZZDDS REQUIRED)

# See c/hello_world/CMakeLists.txt's matching comment: zzdds's own
# build.zig.zon pins zidl to a tagged release URL, which can lag behind a
# zidl checkout with unreleased fixes. Override with -DZIDL_EXECUTABLE=...
# to build against a newer local zidl.
if(NOT DEFINED ZIDL_EXECUTABLE)
    set(ZIDL_EXECUTABLE "${ZZDDS_ZIDL_EXECUTABLE}")
endif()

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

set(RAW_LOAN_IDL "${CMAKE_CURRENT_SOURCE_DIR}/idl/loaned_ping.idl")

add_custom_command(
    OUTPUT "${GENERATED_DIR}/loaned_ping.h" "${GENERATED_DIR}/loaned_ping_cdr.c"
    COMMAND "${ZIDL_EXECUTABLE}" -b c --generate-zzdds-wrappers -o "${GENERATED_DIR}" "${RAW_LOAN_IDL}"
    DEPENDS "${RAW_LOAN_IDL}"
    COMMENT "Generating LoanedPing TypeSupport from loaned_ping.idl"
    VERBATIM
)
add_custom_target(generate_raw_loan_types DEPENDS "${GENERATED_DIR}/loaned_ping.h" "${GENERATED_DIR}/loaned_ping_cdr.c")

add_library(raw_loan_types STATIC "${GENERATED_DIR}/loaned_ping_cdr.c")
add_dependencies(raw_loan_types generate_raw_loan_types)
target_include_directories(raw_loan_types PUBLIC "${GENERATED_DIR}")
target_link_libraries(raw_loan_types PUBLIC ZZDDS::zzdds ZZDDS::zidl_cdr)

add_executable(raw_loan_pub src/publisher.c)
if(MSVC)
    # zzdds's ambient config resolution (getForNewFactory ->
    # resolve.resolveProcessConfig -> toml.parseFile) runs
    # through std.Io.Threaded's single-threaded (inline, no
    # spawned worker) file-read path on this process's own
    # main thread on every process's first factory creation --
    # confirmed by direct checkpoint instrumentation to
    # overflow MSVC's 1MB default stack reserve there, even
    # though it never comes close on Linux's roomier 8MB
    # default. Found building the Windows examples lane
    # (custom-allocator, the only example actually run there
    # so far) but this call path is universal -- every C/C++
    # example hits it, not just this one.
    target_link_options(raw_loan_pub PRIVATE /STACK:8388608)
endif()
target_link_libraries(raw_loan_pub PRIVATE raw_loan_types ZZDDS::zzdds)

add_executable(raw_loan_sub src/subscriber.c)
if(MSVC)
    # zzdds's ambient config resolution (getForNewFactory ->
    # resolve.resolveProcessConfig -> toml.parseFile) runs
    # through std.Io.Threaded's single-threaded (inline, no
    # spawned worker) file-read path on this process's own
    # main thread on every process's first factory creation --
    # confirmed by direct checkpoint instrumentation to
    # overflow MSVC's 1MB default stack reserve there, even
    # though it never comes close on Linux's roomier 8MB
    # default. Found building the Windows examples lane
    # (custom-allocator, the only example actually run there
    # so far) but this call path is universal -- every C/C++
    # example hits it, not just this one.
    target_link_options(raw_loan_sub PRIVATE /STACK:8388608)
endif()
target_link_libraries(raw_loan_sub PRIVATE raw_loan_types ZZDDS::zzdds)
