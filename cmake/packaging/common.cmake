# common packaging (macOS)

set(CPACK_PACKAGE_NAME "Vibepollo")
set(CPACK_PACKAGE_VENDOR "Roguelogic")
set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION_NUMERIC})
set(CPACK_PACKAGE_VERSION_MAJOR ${PROJECT_VERSION_MAJOR})
set(CPACK_PACKAGE_VERSION_MINOR ${PROJECT_VERSION_MINOR})
set(CPACK_PACKAGE_VERSION_PATCH ${PROJECT_VERSION_PATCH})
set(CPACK_PACKAGE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/cpack_artifacts)
set(CPACK_PACKAGE_CONTACT "https://github.com/Roguelogic/Vibepollo/issues")
set(CPACK_PACKAGE_DESCRIPTION ${CMAKE_PROJECT_DESCRIPTION})
set(CPACK_PACKAGE_HOMEPAGE_URL ${CMAKE_PROJECT_HOMEPAGE_URL})
set(CPACK_RESOURCE_FILE_LICENSE ${PROJECT_SOURCE_DIR}/LICENSE)
set(CPACK_PACKAGE_ICON ${PROJECT_SOURCE_DIR}/sunshine.png)
set(CPACK_PACKAGE_FILE_NAME "${CPACK_PACKAGE_NAME}")
set(CPACK_STRIP_FILES YES)

# install common assets
install(DIRECTORY "${SUNSHINE_SOURCE_ASSETS_DIR}/common/assets/"
        DESTINATION "${SUNSHINE_ASSETS_DIR}"
        PATTERN "web" EXCLUDE)

# copy assets to build directory, for running without install
file(GLOB_RECURSE ALL_ASSETS
        RELATIVE "${SUNSHINE_SOURCE_ASSETS_DIR}/common/assets/" "${SUNSHINE_SOURCE_ASSETS_DIR}/common/assets/*")
list(FILTER ALL_ASSETS EXCLUDE REGEX "^web/.*$")
foreach(asset ${ALL_ASSETS})
    get_filename_component(asset_dir "${asset}" DIRECTORY)
    file(COPY "${SUNSHINE_SOURCE_ASSETS_DIR}/common/assets/${asset}"
            DESTINATION "${CMAKE_CURRENT_BINARY_DIR}/assets/${asset_dir}")
endforeach()

install(CODE "
    if(NOT EXISTS \"${CMAKE_CURRENT_BINARY_DIR}/assets/web/index.html\")
        message(FATAL_ERROR \"Vibepollo Web UI is missing. Build the web_ui target before packaging.\")
    endif()
" COMPONENT assets)
install(DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/assets/web/"
        DESTINATION "${SUNSHINE_ASSETS_DIR}/web"
        COMPONENT assets)

include(${CMAKE_MODULE_PATH}/packaging/unix.cmake)
include(${CMAKE_MODULE_PATH}/packaging/macos.cmake)

include(CPack)
