#
# Loads FFmpeg pre-compiled macOS binaries from GitHub releases or a user-specified path
#
include_guard(GLOBAL)

if(NOT DEFINED FFMPEG_PLATFORM_LIBRARIES)
    set(FFMPEG_PLATFORM_LIBRARIES
        "-framework CoreFoundation"
        "-framework CoreMedia"
        "-framework CoreVideo"
        "-framework VideoToolbox"
        "-framework AudioToolbox")
endif()

if(NOT DEFINED FFMPEG_PREPARED_BINARIES)
    include("${CMAKE_CURRENT_LIST_DIR}/ffmpeg-release.cmake")
    set(FFMPEG_ARCHIVE_NAME "${CMAKE_SYSTEM_NAME}-${CMAKE_SYSTEM_PROCESSOR}-ffmpeg.tar.gz")
    set(FFMPEG_HASH_VARIABLE "FFMPEG_SHA256_${CMAKE_SYSTEM_NAME}_${CMAKE_SYSTEM_PROCESSOR}")
    if(NOT DEFINED ${FFMPEG_HASH_VARIABLE})
        message(FATAL_ERROR "No pinned FFmpeg archive for ${FFMPEG_ARCHIVE_NAME}; provide FFMPEG_PREPARED_BINARIES for a custom build")
    endif()
    set(FFMPEG_ARCHIVE_SHA256 "${${FFMPEG_HASH_VARIABLE}}")
    set(FFMPEG_DOWNLOAD_URL "${FFMPEG_RELEASE_URL}/${FFMPEG_ARCHIVE_NAME}")

    set(FFMPEG_VERSION_DIR "${CMAKE_BINARY_DIR}/_deps/ffmpeg-${FFMPEG_ARCHIVE_SHA256}")
    set(FFMPEG_ARCHIVE_PATH "${FFMPEG_VERSION_DIR}/${FFMPEG_ARCHIVE_NAME}")
    set(FFMPEG_PREPARED_BINARIES "${FFMPEG_VERSION_DIR}/ffmpeg")
    file(MAKE_DIRECTORY "${FFMPEG_VERSION_DIR}")

    if(NOT EXISTS "${FFMPEG_ARCHIVE_PATH}")
        message(STATUS "Downloading pinned FFmpeg binaries from ${FFMPEG_DOWNLOAD_URL}")
        set(FFMPEG_DOWNLOAD_PATH "${FFMPEG_ARCHIVE_PATH}.download")
        file(DOWNLOAD
            "${FFMPEG_DOWNLOAD_URL}"
            "${FFMPEG_DOWNLOAD_PATH}"
            EXPECTED_HASH "SHA256=${FFMPEG_ARCHIVE_SHA256}"
            TLS_VERIFY ON
            SHOW_PROGRESS
            STATUS FFMPEG_DOWNLOAD_STATUS
            TIMEOUT 300
        )
        list(GET FFMPEG_DOWNLOAD_STATUS 0 FFMPEG_DOWNLOAD_STATUS_CODE)
        list(GET FFMPEG_DOWNLOAD_STATUS 1 FFMPEG_DOWNLOAD_STATUS_MESSAGE)
        if(NOT FFMPEG_DOWNLOAD_STATUS_CODE EQUAL 0)
            message(FATAL_ERROR "Failed to download FFmpeg binaries: ${FFMPEG_DOWNLOAD_STATUS_MESSAGE}")
        endif()
        file(RENAME "${FFMPEG_DOWNLOAD_PATH}" "${FFMPEG_ARCHIVE_PATH}")
    endif()

    file(SHA256 "${FFMPEG_ARCHIVE_PATH}" FFMPEG_CACHED_SHA256)
    if(NOT FFMPEG_CACHED_SHA256 STREQUAL FFMPEG_ARCHIVE_SHA256)
        message(FATAL_ERROR "FFmpeg archive checksum mismatch: ${FFMPEG_ARCHIVE_PATH}")
    endif()
    if(NOT EXISTS "${FFMPEG_PREPARED_BINARIES}/lib/libavcodec.a")
        file(ARCHIVE_EXTRACT  # cmake-lint: disable=E1126
            INPUT "${FFMPEG_ARCHIVE_PATH}"
            DESTINATION "${FFMPEG_VERSION_DIR}"
        )
        if(NOT EXISTS "${FFMPEG_PREPARED_BINARIES}/lib/libavcodec.a")
            message(FATAL_ERROR "FFmpeg extraction failed or unexpected directory structure")
        endif()
    endif()
    message(STATUS "Using pinned FFmpeg ${FFMPEG_RELEASE_TAG}: ${FFMPEG_ARCHIVE_SHA256}")

    if(EXISTS "${FFMPEG_PREPARED_BINARIES}/lib/libhdr10plus.a")
        set(HDR10_PLUS_LIBRARY "${FFMPEG_PREPARED_BINARIES}/lib/libhdr10plus.a")
    endif()

    set(FFMPEG_LIBRARIES
        "${FFMPEG_PREPARED_BINARIES}/lib/libavcodec.a"
        "${FFMPEG_PREPARED_BINARIES}/lib/libswscale.a"
        "${FFMPEG_PREPARED_BINARIES}/lib/libavutil.a"
        "${FFMPEG_PREPARED_BINARIES}/lib/libcbs.a"
        "${FFMPEG_PREPARED_BINARIES}/lib/libSvtAv1Enc.a"
        "${FFMPEG_PREPARED_BINARIES}/lib/libx264.a"
        "${FFMPEG_PREPARED_BINARIES}/lib/libx265.a"
        ${HDR10_PLUS_LIBRARY}
        ${FFMPEG_PLATFORM_LIBRARIES}
    )
else()
    message(STATUS "Using user-specified FFmpeg binaries at ${FFMPEG_PREPARED_BINARIES}")

    set(FFMPEG_LIBRARIES
        "${FFMPEG_PREPARED_BINARIES}/lib/libavcodec.a"
        "${FFMPEG_PREPARED_BINARIES}/lib/libswscale.a"
        "${FFMPEG_PREPARED_BINARIES}/lib/libavutil.a"
        "${FFMPEG_PREPARED_BINARIES}/lib/libcbs.a"
    )

    if(EXISTS "${FFMPEG_PREPARED_BINARIES}/lib/libSvtAv1Enc.a")
        list(APPEND FFMPEG_LIBRARIES "${FFMPEG_PREPARED_BINARIES}/lib/libSvtAv1Enc.a")
    endif()
    if(EXISTS "${FFMPEG_PREPARED_BINARIES}/lib/libx264.a")
        list(APPEND FFMPEG_LIBRARIES "${FFMPEG_PREPARED_BINARIES}/lib/libx264.a")
    endif()
    if(EXISTS "${FFMPEG_PREPARED_BINARIES}/lib/libx265.a")
        list(APPEND FFMPEG_LIBRARIES "${FFMPEG_PREPARED_BINARIES}/lib/libx265.a")
    endif()
    if(EXISTS "${FFMPEG_PREPARED_BINARIES}/lib/libhdr10plus.a")
        list(APPEND FFMPEG_LIBRARIES "${FFMPEG_PREPARED_BINARIES}/lib/libhdr10plus.a")
    endif()

    list(APPEND FFMPEG_LIBRARIES ${FFMPEG_PLATFORM_LIBRARIES})
endif()

set(FFMPEG_INCLUDE_DIRS "${FFMPEG_PREPARED_BINARIES}/include")
