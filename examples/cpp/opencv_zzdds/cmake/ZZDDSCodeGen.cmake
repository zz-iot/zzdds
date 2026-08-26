# ZZDDSCodeGen.cmake
#
# Provides zzdds_add_idl() — a CMake wrapper around the zidl IDL compiler that
# adds a build-time code-generation step and wires the generated sources into a
# target.
#
# Requires: ZZDDS::zzdds imported target (from FindZZDDS.cmake) and
#           ZZDDS_ZIDL_EXECUTABLE.
#
# Usage:
#
#   zzdds_add_idl(<target>
#       IDL_FILE   <path-to-idl>
#       [LANGUAGE  cpp|c]            # default: cpp
#       [WRAPPERS]                   # pass --generate-zzdds-wrappers
#       [SPLIT_FILES]                # pass --split-files
#       [OUTPUT_DIR <dir>]           # default: ${CMAKE_CURRENT_BINARY_DIR}/zzdds-gen
#       [DEFINES  <D1> <D2> ...]     # preprocessor defines passed to zidl (-D)
#   )
#
#   The function:
#     - Runs zidl at build time to produce .hpp and _cdr.cpp files
#     - Adds generated sources to <target>
#     - Adds the output directory to <target>'s include path
#     - Links <target> against ZZDDS::zzdds
#
#   The zidl_cdr.c runtime file must also be compiled once per executable.
#   See the CMakeLists.txt in this project for the pattern.

cmake_minimum_required(VERSION 3.16)

function(zzdds_add_idl target)
    cmake_parse_arguments(ARG
        "WRAPPERS;SPLIT_FILES"
        "IDL_FILE;LANGUAGE;OUTPUT_DIR"
        "DEFINES"
        ${ARGN}
    )

    if(NOT ARG_IDL_FILE)
        message(FATAL_ERROR "zzdds_add_idl: IDL_FILE is required")
    endif()

    if(NOT ARG_LANGUAGE)
        set(ARG_LANGUAGE "cpp")
    endif()

    if(NOT ARG_OUTPUT_DIR)
        set(ARG_OUTPUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/zzdds-gen")
    endif()

    if(NOT ZZDDS_ZIDL_EXECUTABLE)
        message(FATAL_ERROR
            "zzdds_add_idl: ZZDDS_ZIDL_EXECUTABLE not set. "
            "Install zidl or set ZZDDS_ROOT to a full zzdds install.")
    endif()

    get_filename_component(_idl_abs "${ARG_IDL_FILE}" ABSOLUTE
                           BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
    get_filename_component(_stem "${ARG_IDL_FILE}" NAME_WLE)

    # Build the zidl command line
    set(_zidl_args -b "${ARG_LANGUAGE}")
    if(ARG_WRAPPERS)
        list(APPEND _zidl_args --generate-zzdds-wrappers)
    endif()
    if(ARG_SPLIT_FILES)
        list(APPEND _zidl_args --split-files)
    endif()
    foreach(_def IN LISTS ARG_DEFINES)
        list(APPEND _zidl_args -D "${_def}")
    endforeach()
    list(APPEND _zidl_args -o "${ARG_OUTPUT_DIR}" "${_idl_abs}")

    # Predict generated output file names (matches zidl single-file output)
    if(ARG_LANGUAGE STREQUAL "cpp")
        set(_gen_header  "${ARG_OUTPUT_DIR}/${_stem}.hpp")
        set(_gen_cdr_src "${ARG_OUTPUT_DIR}/${_stem}_cdr.cpp")
        set(_gen_outputs "${_gen_header}" "${_gen_cdr_src}")
    else()
        set(_gen_header  "${ARG_OUTPUT_DIR}/${_stem}.h")
        set(_gen_cdr_src "${ARG_OUTPUT_DIR}/${_stem}_cdr.c")
        set(_gen_outputs "${_gen_header}" "${_gen_cdr_src}")
    endif()

    file(MAKE_DIRECTORY "${ARG_OUTPUT_DIR}")

    add_custom_command(
        OUTPUT  ${_gen_outputs}
        COMMAND "${ZZDDS_ZIDL_EXECUTABLE}" ${_zidl_args}
        DEPENDS "${_idl_abs}"
        COMMENT "Generating ${ARG_LANGUAGE} bindings for ${ARG_IDL_FILE}"
        VERBATIM
    )

    target_sources("${target}" PRIVATE "${_gen_cdr_src}")
    target_include_directories("${target}" PRIVATE "${ARG_OUTPUT_DIR}")
    target_link_libraries("${target}" PRIVATE ZZDDS::zzdds)
endfunction()
