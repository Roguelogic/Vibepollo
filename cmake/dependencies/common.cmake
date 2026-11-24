# load macOS dependencies

# Resolve OpenSSL before subprojects run their own find_package(OpenSSL) calls.
# Prefer static archives for self-contained .app bundles so dead_strip removes unused
# crypto algorithms and avoids bundling libssl/libcrypto dylibs in Contents/Frameworks.
if(NOT SUNSHINE_BUILD_HOMEBREW AND NOT DEFINED OPENSSL_USE_STATIC_LIBS)
    set(OPENSSL_USE_STATIC_LIBS ON CACHE BOOL "Use static OpenSSL libraries for self-contained .app bundles")
endif()
find_package(OpenSSL REQUIRED)

# boost, this should be before Simple-Web-Server as it also depends on boost
include(dependencies/Boost_Sunshine)

# submodules
# moonlight common library
set(ENET_NO_INSTALL ON CACHE BOOL "Don't install any libraries built for enet")
add_subdirectory("${CMAKE_SOURCE_DIR}/third-party/moonlight-common-c/enet")
if(TARGET enet)
    target_compile_options(enet PRIVATE -include "${CMAKE_SOURCE_DIR}/src/platform/macos/enet_pktinfo_shim.h")
endif()

# web server
add_subdirectory("${CMAKE_SOURCE_DIR}/third-party/Simple-Web-Server")

# libdisplaydevice
add_subdirectory("${CMAKE_SOURCE_DIR}/third-party/libdisplaydevice")

# common dependencies
include("${CMAKE_MODULE_PATH}/dependencies/nlohmann_json.cmake")
find_package(PkgConfig REQUIRED)
find_package(Threads REQUIRED)
pkg_check_modules(CURL REQUIRED libcurl)

# SQLite3 (session history persistence)
pkg_check_modules(SQLITE3 REQUIRED sqlite3)

# miniupnp (prefer static archive for self-contained .app bundles with zero third-party dylibs)
pkg_check_modules(MINIUPNP miniupnpc REQUIRED)
include_directories(SYSTEM ${MINIUPNP_INCLUDE_DIRS})
if(NOT SUNSHINE_BUILD_HOMEBREW)
    find_library(MINIUPNP_STATIC_LIBRARY
            NAMES libminiupnpc.a
            PATHS ${MINIUPNP_LIBRARY_DIRS}
            NO_DEFAULT_PATH)
    if(MINIUPNP_STATIC_LIBRARY)
        set(MINIUPNP_LIBRARIES "${MINIUPNP_STATIC_LIBRARY}")
    endif()
endif()

# ffmpeg pre-compiled binaries
include("${CMAKE_MODULE_PATH}/dependencies/ffmpeg.cmake")

# Opus
# Homebrew provides opus as a dynamic library only, so disable static linking for Homebrew builds
if(SUNSHINE_BUILD_HOMEBREW)
    set(OPUS_USE_STATIC OFF CACHE BOOL "Static linking for libopus")
else()
    set(OPUS_USE_STATIC ON CACHE BOOL "Static linking for libopus")
endif()
include("${CMAKE_MODULE_PATH}/dependencies/FindOpus.cmake")

# macOS platform dependencies
include("${CMAKE_MODULE_PATH}/dependencies/unix.cmake")
include("${CMAKE_MODULE_PATH}/dependencies/macos.cmake")

# PyroWave codec library (optional, disabled by default on macOS)
include("${CMAKE_MODULE_PATH}/dependencies/pyrowave.cmake")
