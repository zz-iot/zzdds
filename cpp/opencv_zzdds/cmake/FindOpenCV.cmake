# FindOpenCV.cmake
#
# Locates OpenCV on systems (e.g. Debian/Ubuntu) where the dev packages do not
# ship a cmake config file.  If OpenCV ships its own config, CMake will prefer
# that; this module is a fallback.
#
# After find_package(OpenCV) the following are set:
#
#   OpenCV_FOUND
#   OpenCV_INCLUDE_DIRS
#   OpenCV_LIBRARIES
#   OpenCV::opencv_<component>  imported targets for each found COMPONENT
#
# Recognised components: core highgui imgcodecs imgproc ml objdetect videoio
# Default (no COMPONENTS): all of the above.

cmake_minimum_required(VERSION 3.14)

set(_opencv_known_components core highgui imgcodecs imgproc ml objdetect videoio)

if(NOT OpenCV_FIND_COMPONENTS)
    set(OpenCV_FIND_COMPONENTS ${_opencv_known_components})
endif()

# Headers live under /usr/include/opencv4 on Debian
find_path(OpenCV_INCLUDE_DIR
    NAMES opencv2/core.hpp
    PATHS /usr/include/opencv4 /usr/local/include/opencv4
          /usr/include             /usr/local/include
    DOC "OpenCV include directory"
)

set(OpenCV_LIBRARIES "")
set(OpenCV_FOUND_COMPONENTS "")

foreach(_comp IN LISTS OpenCV_FIND_COMPONENTS)
    find_library(_opencv_lib_${_comp}
        NAMES "opencv_${_comp}"
        PATHS /usr/lib /usr/lib/x86_64-linux-gnu /usr/local/lib
        DOC "OpenCV ${_comp} library"
    )
    if(_opencv_lib_${_comp})
        list(APPEND OpenCV_LIBRARIES "${_opencv_lib_${_comp}}")
        list(APPEND OpenCV_FOUND_COMPONENTS "${_comp}")

        if(NOT TARGET OpenCV::opencv_${_comp})
            add_library(OpenCV::opencv_${_comp} SHARED IMPORTED)
            set_target_properties(OpenCV::opencv_${_comp} PROPERTIES
                IMPORTED_LOCATION "${_opencv_lib_${_comp}}"
                INTERFACE_INCLUDE_DIRECTORIES "${OpenCV_INCLUDE_DIR}"
            )
        endif()
    elseif(OpenCV_FIND_REQUIRED_${_comp})
        message(SEND_ERROR "FindOpenCV: required component ${_comp} not found")
    endif()
    unset(_opencv_lib_${_comp} CACHE)
endforeach()

set(OpenCV_INCLUDE_DIRS "${OpenCV_INCLUDE_DIR}")

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(OpenCV
    REQUIRED_VARS OpenCV_INCLUDE_DIR
    FAIL_MESSAGE  "Could not find OpenCV headers. Install libopencv-dev."
)

mark_as_advanced(OpenCV_INCLUDE_DIR)
