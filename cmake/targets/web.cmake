set(SUNSHINE_WEB_SOURCE_DIR "${SUNSHINE_SOURCE_ASSETS_DIR}/common/assets/web")
set(SUNSHINE_WEB_OUTPUT_DIR "${CMAKE_BINARY_DIR}/assets/web")
set(SUNSHINE_WEB_STAMP "${SUNSHINE_WEB_OUTPUT_DIR}/.build-stamp")

file(GLOB_RECURSE SUNSHINE_WEB_SOURCES
    LIST_DIRECTORIES FALSE
    "${SUNSHINE_WEB_SOURCE_DIR}/*")
list(FILTER SUNSHINE_WEB_SOURCES EXCLUDE REGEX "/(\\.DS_Store|\\.build-stamp)$")

add_custom_command(
    OUTPUT
        "${SUNSHINE_WEB_STAMP}"
        "${SUNSHINE_WEB_OUTPUT_DIR}/index.html"
    COMMAND "${CMAKE_COMMAND}" -E remove_directory "${SUNSHINE_WEB_OUTPUT_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${SUNSHINE_WEB_OUTPUT_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory "${SUNSHINE_WEB_SOURCE_DIR}" "${SUNSHINE_WEB_OUTPUT_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E touch "${SUNSHINE_WEB_STAMP}"
    DEPENDS ${SUNSHINE_WEB_SOURCES}
    COMMENT "Staging lightweight Vibepollo remote web console"
)
add_custom_target(web_ui DEPENDS
    "${SUNSHINE_WEB_STAMP}"
    "${SUNSHINE_WEB_OUTPUT_DIR}/index.html")
