set(SUNSHINE_WEB_SOURCE_DIR "${SUNSHINE_SOURCE_ASSETS_DIR}/common/assets/web")
set(SUNSHINE_WEB_OUTPUT_DIR "${CMAKE_BINARY_DIR}/assets/web")
set(SUNSHINE_WEB_STAMP "${SUNSHINE_WEB_OUTPUT_DIR}/.build-stamp")

set(SUNSHINE_WEB_SOURCES)
file(GLOB SUNSHINE_WEB_APPLICATION_ROOT_SOURCES
    LIST_DIRECTORIES TRUE
    "${SUNSHINE_WEB_SOURCE_DIR}/*")
list(FILTER SUNSHINE_WEB_APPLICATION_ROOT_SOURCES EXCLUDE REGEX "/(node_modules|dist|\\.vite|\\.cache|coverage)/?$")
foreach(SUNSHINE_WEB_APPLICATION_ROOT_SOURCE IN LISTS SUNSHINE_WEB_APPLICATION_ROOT_SOURCES)
    if(IS_DIRECTORY "${SUNSHINE_WEB_APPLICATION_ROOT_SOURCE}")
        file(GLOB_RECURSE SUNSHINE_WEB_APPLICATION_SUBDIR_SOURCES
            LIST_DIRECTORIES FALSE
            "${SUNSHINE_WEB_APPLICATION_ROOT_SOURCE}/*")
        list(FILTER SUNSHINE_WEB_APPLICATION_SUBDIR_SOURCES EXCLUDE REGEX "/(node_modules|dist|\\.vite|\\.cache|coverage)/")
        list(APPEND SUNSHINE_WEB_SOURCES ${SUNSHINE_WEB_APPLICATION_SUBDIR_SOURCES})
    else()
        list(APPEND SUNSHINE_WEB_SOURCES "${SUNSHINE_WEB_APPLICATION_ROOT_SOURCE}")
    endif()
endforeach()
list(REMOVE_DUPLICATES SUNSHINE_WEB_SOURCES)

find_program(SUNSHINE_NPM_EXECUTABLE NAMES npm)

if(SUNSHINE_NPM_EXECUTABLE)
    add_custom_command(
        OUTPUT
            "${SUNSHINE_WEB_STAMP}"
            "${SUNSHINE_WEB_OUTPUT_DIR}/index.html"
        COMMAND "${SUNSHINE_NPM_EXECUTABLE}" ci --ignore-scripts --no-audit --no-fund --prefer-offline
        COMMAND "${CMAKE_COMMAND}" -E env
                "SUNSHINE_WEB_OUTPUT_DIR=${SUNSHINE_WEB_OUTPUT_DIR}"
                "${SUNSHINE_NPM_EXECUTABLE}" run build
        COMMAND "${CMAKE_COMMAND}" -E touch "${SUNSHINE_WEB_STAMP}"
        WORKING_DIRECTORY "${SUNSHINE_WEB_SOURCE_DIR}"
        DEPENDS ${SUNSHINE_WEB_SOURCES}
        COMMENT "Building the Vibepollo macOS web console"
        USES_TERMINAL
    )
    add_custom_target(web_ui DEPENDS
        "${SUNSHINE_WEB_STAMP}"
        "${SUNSHINE_WEB_OUTPUT_DIR}/index.html")
else()
    add_custom_target(web_ui
        COMMAND "${CMAKE_COMMAND}" -E echo "npm is required to build the Vibepollo browser interface"
        COMMAND "${CMAKE_COMMAND}" -E false
        COMMENT "Unable to build the Vibepollo browser interface"
    )
endif()
