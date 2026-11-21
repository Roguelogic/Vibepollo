# common target definitions (macOS)

if(NOT SUNSHINE_BUILD_HOMEBREW)
    add_executable(sunshine MACOSX_BUNDLE ${SUNSHINE_TARGET_FILES})
else()
    add_executable(sunshine ${SUNSHINE_TARGET_FILES})
endif()
foreach(dep ${SUNSHINE_TARGET_DEPENDENCIES})
    add_dependencies(sunshine ${dep})
endforeach()

include(${CMAKE_MODULE_PATH}/targets/web.cmake)
add_dependencies(sunshine web_ui)

include(${CMAKE_MODULE_PATH}/targets/unix.cmake)
include(${CMAKE_MODULE_PATH}/targets/macos.cmake)

target_link_libraries(sunshine ${SUNSHINE_EXTERNAL_LIBRARIES} ${EXTRA_LIBS})
target_compile_definitions(sunshine PUBLIC ${SUNSHINE_DEFINITIONS})

set_target_properties(sunshine PROPERTIES CXX_STANDARD 23)
if(SUNSHINE_BUILD_HOMEBREW)
    set_target_properties(sunshine PROPERTIES
            VERSION ${PROJECT_VERSION}
            SOVERSION ${PROJECT_VERSION_MAJOR})
endif()

target_compile_options(sunshine PRIVATE $<$<COMPILE_LANGUAGE:CXX>:${SUNSHINE_COMPILE_OPTIONS}>)

# src/upnp
set_source_files_properties("${CMAKE_SOURCE_DIR}/src/upnp.cpp"
        DIRECTORY "${CMAKE_SOURCE_DIR}"
        PROPERTIES COMPILE_FLAGS -Wno-pedantic)

# third-party/nanors
set_source_files_properties("${CMAKE_SOURCE_DIR}/src/rswrapper.c"
        DIRECTORY "${CMAKE_SOURCE_DIR}"
        PROPERTIES COMPILE_FLAGS "-ftree-vectorize -funroll-loops")

string(TOUPPER "x${CMAKE_BUILD_TYPE}" BUILD_TYPE)
if(NOT "${BUILD_TYPE}" STREQUAL "XDEBUG")
    add_definitions(-DNDEBUG)
endif()
