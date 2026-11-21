# common macros (macOS)

if(CMAKE_VERSION VERSION_GREATER_EQUAL "3.30")
    cmake_policy(SET CMP0167 NEW)
endif()

include(${CMAKE_MODULE_PATH}/macros/unix.cmake)
include(${CMAKE_MODULE_PATH}/macros/macos.cmake)

# override find_package function so subprojects reuse FetchContent Boost
macro(find_package)  # cmake-lint: disable=C0103
    string(TOLOWER "${ARGV0}" ARGV0_LOWER)
    if(("${ARGV0_LOWER}" STREQUAL "boost") AND DEFINED FETCH_CONTENT_BOOST_USED)
        # Do nothing, as Boost has already been fetched
    else()
        _find_package(${ARGV})
    endif()
endmacro()
