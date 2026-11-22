# common compile definitions (macOS)

list(APPEND SUNSHINE_COMPILE_OPTIONS -Wall -Wno-sign-compare)
if(BUILD_WERROR)
    list(APPEND SUNSHINE_COMPILE_OPTIONS -Werror)
endif()

if(NOT SUNSHINE_ASSETS_DIR)
    set(SUNSHINE_ASSETS_DIR "assets")
endif()

include(${CMAKE_MODULE_PATH}/compile_definitions/unix.cmake)
include(${CMAKE_MODULE_PATH}/compile_definitions/macos.cmake)

set(SUNSHINE_TARGET_FILES
        "${CMAKE_SOURCE_DIR}/third-party/moonlight-common-c/src/Input.h"
        "${CMAKE_SOURCE_DIR}/third-party/moonlight-common-c/src/Rtsp.h"
        "${CMAKE_SOURCE_DIR}/third-party/moonlight-common-c/src/RtspParser.c"
        "${CMAKE_SOURCE_DIR}/third-party/moonlight-common-c/src/Video.h"
        "${CMAKE_SOURCE_DIR}/third-party/tray/src/tray.h"
        "${CMAKE_SOURCE_DIR}/src/upnp.cpp"
        "${CMAKE_SOURCE_DIR}/src/upnp.h"
        "${CMAKE_SOURCE_DIR}/src/cbs.cpp"
        "${CMAKE_SOURCE_DIR}/src/utility.h"
        "${CMAKE_SOURCE_DIR}/src/uuid.h"
        "${CMAKE_SOURCE_DIR}/src/config.h"
        "${CMAKE_SOURCE_DIR}/src/config.cpp"
        "${CMAKE_SOURCE_DIR}/src/display_device.h"
        "${CMAKE_SOURCE_DIR}/src/display_device.cpp"
        "${CMAKE_SOURCE_DIR}/src/display_device_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/entry_handler.cpp"
        "${CMAKE_SOURCE_DIR}/src/entry_handler.h"
        "${CMAKE_SOURCE_DIR}/src/entry_metadata.cpp"
        "${CMAKE_SOURCE_DIR}/src/entry_metadata.h"
        "${CMAKE_SOURCE_DIR}/src/file_handler.cpp"
        "${CMAKE_SOURCE_DIR}/src/file_handler_core.cpp"
        "${CMAKE_SOURCE_DIR}/src/file_handler.h"
        "${CMAKE_SOURCE_DIR}/src/globals.cpp"
        "${CMAKE_SOURCE_DIR}/src/globals.h"
        "${CMAKE_SOURCE_DIR}/src/logging.cpp"
        "${CMAKE_SOURCE_DIR}/src/logging.h"
        "${CMAKE_SOURCE_DIR}/src/logging_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/logging_policy.h"
        "${CMAKE_SOURCE_DIR}/src/main.cpp"
        "${CMAKE_SOURCE_DIR}/src/main.h"
        "${CMAKE_SOURCE_DIR}/src/update.cpp"
        "${CMAKE_SOURCE_DIR}/src/update.h"
        "${CMAKE_SOURCE_DIR}/src/crypto.cpp"
        "${CMAKE_SOURCE_DIR}/src/crypto.h"
        "${CMAKE_SOURCE_DIR}/src/http_pairing_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/http_pairing_policy.h"
        "${CMAKE_SOURCE_DIR}/src/pairing_recovery.cpp"
        "${CMAKE_SOURCE_DIR}/src/pairing_recovery.h"
        "${CMAKE_SOURCE_DIR}/src/remote_session.cpp"
        "${CMAKE_SOURCE_DIR}/src/remote_session.h"
        "${CMAKE_SOURCE_DIR}/src/rtsp_pending_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/rtsp_pending_policy.h"
        "${CMAKE_SOURCE_DIR}/src/remote_display_topology.cpp"
        "${CMAKE_SOURCE_DIR}/src/remote_display_topology.h"
        "${CMAKE_SOURCE_DIR}/src/tls_client_identity.cpp"
        "${CMAKE_SOURCE_DIR}/src/tls_client_identity.h"
        "${CMAKE_SOURCE_DIR}/src/tls_client_identity_native.cpp"
        "${CMAKE_SOURCE_DIR}/src/tls_client_identity_native.h"
        "${CMAKE_SOURCE_DIR}/src/nvhttp_server.h"
        "${CMAKE_SOURCE_DIR}/src/nvhttp.cpp"
        "${CMAKE_SOURCE_DIR}/src/nvhttp.h"
        "${CMAKE_SOURCE_DIR}/src/nvhttp_dispatch.h"
        "${CMAKE_SOURCE_DIR}/src/power_action.cpp"
        "${CMAKE_SOURCE_DIR}/src/power_action.h"
        "${CMAKE_SOURCE_DIR}/src/power_action_http.h"
        "${CMAKE_SOURCE_DIR}/src/power_action_native.cpp"
        "${CMAKE_SOURCE_DIR}/src/nvhttp_bitrate_policy.h"
        "${CMAKE_SOURCE_DIR}/src/httpcommon.cpp"
        "${CMAKE_SOURCE_DIR}/src/http_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/httpcommon.h"
        "${CMAKE_SOURCE_DIR}/src/confighttp.cpp"
        "${CMAKE_SOURCE_DIR}/src/config_http_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/confighttp_steam.cpp"
        "${CMAKE_SOURCE_DIR}/src/confighttp.h"
        "${CMAKE_SOURCE_DIR}/src/webrtc_stream.cpp"
        "${CMAKE_SOURCE_DIR}/src/webrtc_stream.h"
        "${CMAKE_SOURCE_DIR}/src/usb_stream_tunnel.cpp"
        "${CMAKE_SOURCE_DIR}/src/usb_stream_tunnel.h"
        "${CMAKE_SOURCE_DIR}/src/rtsp.cpp"
        "${CMAKE_SOURCE_DIR}/src/rtsp.h"
        "${CMAKE_SOURCE_DIR}/src/stream.cpp"
        "${CMAKE_SOURCE_DIR}/src/stream_broadcast_runtime.cpp"
        "${CMAKE_SOURCE_DIR}/src/stream_broadcast_runtime.h"
        "${CMAKE_SOURCE_DIR}/src/stream_protocol.cpp"
        "${CMAKE_SOURCE_DIR}/src/stream.h"
        "${CMAKE_SOURCE_DIR}/src/video.cpp"
        "${CMAKE_SOURCE_DIR}/src/video_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/video.h"
        "${CMAKE_SOURCE_DIR}/src/video_colorspace.cpp"
        "${CMAKE_SOURCE_DIR}/src/video_colorspace.h"
        "${CMAKE_SOURCE_DIR}/src/pyrowave_host.cpp"
        "${CMAKE_SOURCE_DIR}/src/pyrowave_host.h"
        "${CMAKE_SOURCE_DIR}/src/pyrowave_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/pyrowave_policy.h"
        "${CMAKE_SOURCE_DIR}/src/pyrowave_protocol.h"
        "${CMAKE_SOURCE_DIR}/src/input.cpp"
        "${CMAKE_SOURCE_DIR}/src/input.h"
        "${CMAKE_SOURCE_DIR}/src/input_validation_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/input_validation_policy.h"
        "${CMAKE_SOURCE_DIR}/src/mouse_input.cpp"
        "${CMAKE_SOURCE_DIR}/src/mouse_input.h"
        "${CMAKE_SOURCE_DIR}/src/audio.cpp"
        "${CMAKE_SOURCE_DIR}/src/audio_context.cpp"
        "${CMAKE_SOURCE_DIR}/src/audio_context.h"
        "${CMAKE_SOURCE_DIR}/src/audio_display_transition.h"
        "${CMAKE_SOURCE_DIR}/src/config_display_transition.h"
        "${CMAKE_SOURCE_DIR}/src/audio_role_control.h"
        "${CMAKE_SOURCE_DIR}/src/webrtc_capture_owner.h"
        "${CMAKE_SOURCE_DIR}/src/platform/audio.h"
        "${CMAKE_SOURCE_DIR}/src/audio.h"
        "${CMAKE_SOURCE_DIR}/src/audio_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/audio_policy.h"
        "${CMAKE_SOURCE_DIR}/src/platform/common.h"
        "${CMAKE_SOURCE_DIR}/src/platform/common_services.cpp"
        "${CMAKE_SOURCE_DIR}/src/platform/common_services.h"
        "${CMAKE_SOURCE_DIR}/src/app_catalog_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/app_catalog_policy.h"
        "${CMAKE_SOURCE_DIR}/src/steam_integration.cpp"
        "${CMAKE_SOURCE_DIR}/src/steam_integration.h"
        "${CMAKE_SOURCE_DIR}/src/steam_controller_protocol.h"
        "${CMAKE_SOURCE_DIR}/src/steam_artwork.cpp"
        "${CMAKE_SOURCE_DIR}/src/steam_artwork.h"
        "${CMAKE_SOURCE_DIR}/src/steam_sync_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/steam_sync_policy.h"
        "${CMAKE_SOURCE_DIR}/src/steam_auto_sync.cpp"
        "${CMAKE_SOURCE_DIR}/src/steam_auto_sync.h"
        "${CMAKE_SOURCE_DIR}/src/steam_auto_sync_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/steam_auto_sync_policy.h"
        "${CMAKE_SOURCE_DIR}/src/managed_app_focus.cpp"
        "${CMAKE_SOURCE_DIR}/src/steam_process_tracker.cpp"
        "${CMAKE_SOURCE_DIR}/src/steam_process_tracker.h"
        "${CMAKE_SOURCE_DIR}/src/config_steam.cpp"
        "${CMAKE_SOURCE_DIR}/src/config_steam.h"
        "${CMAKE_SOURCE_DIR}/src/provider_scan_protocol.cpp"
        "${CMAKE_SOURCE_DIR}/src/provider_scan_protocol.h"
        "${CMAKE_SOURCE_DIR}/src/app_framegen_config.cpp"
        "${CMAKE_SOURCE_DIR}/src/app_framegen_config.h"
        "${CMAKE_SOURCE_DIR}/src/deferred_action.h"
        "${CMAKE_SOURCE_DIR}/src/paused_app_monitor.h"
        "${CMAKE_SOURCE_DIR}/src/process_catalog.cpp"
        "${CMAKE_SOURCE_DIR}/src/process_catalog.h"
        "${CMAKE_SOURCE_DIR}/src/process_context.h"
        "${CMAKE_SOURCE_DIR}/src/process.cpp"
        "${CMAKE_SOURCE_DIR}/src/process.h"
        "${CMAKE_SOURCE_DIR}/src/boost_process_shim.cpp"
        "${CMAKE_SOURCE_DIR}/src/boost_process_shim.h"
        "${CMAKE_SOURCE_DIR}/src/network.cpp"
        "${CMAKE_SOURCE_DIR}/src/network.h"
        "${CMAKE_SOURCE_DIR}/src/network_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/network_policy.h"
        "${CMAKE_SOURCE_DIR}/src/move_by_copy.h"
        "${CMAKE_SOURCE_DIR}/src/system_tray.cpp"
        "${CMAKE_SOURCE_DIR}/src/system_tray.h"
        "${CMAKE_SOURCE_DIR}/src/task_pool.h"
        "${CMAKE_SOURCE_DIR}/src/thread_pool.h"
        "${CMAKE_SOURCE_DIR}/src/thread_safe.h"
        "${CMAKE_SOURCE_DIR}/src/sync.h"
        "${CMAKE_SOURCE_DIR}/src/round_robin.h"
        "${CMAKE_SOURCE_DIR}/src/stat_trackers.h"
        "${CMAKE_SOURCE_DIR}/src/stat_trackers.cpp"
        "${CMAKE_SOURCE_DIR}/src/rswrapper.h"
        "${CMAKE_SOURCE_DIR}/src/rswrapper.c"
        "${CMAKE_SOURCE_DIR}/src/http_auth.cpp"
        "${CMAKE_SOURCE_DIR}/src/http_auth_request_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/state_storage.cpp"
        "${CMAKE_SOURCE_DIR}/src/state_storage.h"
        "${CMAKE_SOURCE_DIR}/src/state_storage_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/state_storage_policy.h"
        "${CMAKE_SOURCE_DIR}/src/session_history.cpp"
        "${CMAKE_SOURCE_DIR}/src/session_history.h"
        "${CMAKE_SOURCE_DIR}/src/session_history_sampler.cpp"
        "${CMAKE_SOURCE_DIR}/src/session_history_sampler.h"
        "${CMAKE_SOURCE_DIR}/src/session_history_storage.cpp"
        "${CMAKE_SOURCE_DIR}/src/session_history_storage.h"
        "${CMAKE_SOURCE_DIR}/src/session_history_storage_diagnostics.cpp"
        "${CMAKE_SOURCE_DIR}/src/session_history_storage_diagnostics.h"
        "${CMAKE_SOURCE_DIR}/src/session_history_policy.cpp"
        "${CMAKE_SOURCE_DIR}/src/session_history_policy.h"
        "${CMAKE_SOURCE_DIR}/src/session_history_writer.cpp"
        "${CMAKE_SOURCE_DIR}/src/session_history_writer.h"
        "${CMAKE_SOURCE_DIR}/src/host_stats.cpp"
        "${CMAKE_SOURCE_DIR}/src/host_stats.h"
        "${CMAKE_SOURCE_DIR}/src/host_stats_service.cpp"
        "${CMAKE_SOURCE_DIR}/src/hardware_metrics.cpp"
        "${CMAKE_SOURCE_DIR}/src/hardware_metrics.h"
        "${CMAKE_SOURCE_DIR}/src/host_stats_service.h"
        "${CMAKE_SOURCE_DIR}/src/host_stats_types.h"
        ${PLATFORM_TARGET_FILES})

if(NOT SUNSHINE_ASSETS_DIR_DEF)
    set(SUNSHINE_ASSETS_DIR_DEF "${SUNSHINE_ASSETS_DIR}")
endif()
list(APPEND SUNSHINE_DEFINITIONS SUNSHINE_ASSETS_DIR="${SUNSHINE_ASSETS_DIR_DEF}")
list(APPEND SUNSHINE_DEFINITIONS SUNSHINE_TRAY=${SUNSHINE_TRAY})

# Publisher metadata
list(APPEND SUNSHINE_DEFINITIONS SUNSHINE_PUBLISHER_NAME="${SUNSHINE_PUBLISHER_NAME}")
list(APPEND SUNSHINE_DEFINITIONS SUNSHINE_PUBLISHER_WEBSITE="${SUNSHINE_PUBLISHER_WEBSITE}")
list(APPEND SUNSHINE_DEFINITIONS SUNSHINE_PUBLISHER_ISSUE_URL="${SUNSHINE_PUBLISHER_ISSUE_URL}")
list(APPEND SUNSHINE_DEFINITIONS SETUP_AV_LOGGING="1")
list(APPEND SUNSHINE_DEFINITIONS SETUP_LIBDISPLAYDEVICE_LOGGING="1")

include_directories(BEFORE "${CMAKE_SOURCE_DIR}")

set(SUNSHINE_FFMPEG_INCLUDE_DIRS ${FFMPEG_INCLUDE_DIRS})

find_package(PNG QUIET)
find_package(JPEG QUIET)
find_library(STEAM_ARTWORK_WEBP_LIBRARY NAMES webp)
if(PNG_FOUND AND JPEG_FOUND AND STEAM_ARTWORK_WEBP_LIBRARY)
    list(APPEND SUNSHINE_DEFINITIONS VIBEPOLLO_STEAM_ARTWORK_IMAGE_LIBS=1)
    list(APPEND SUNSHINE_EXTERNAL_LIBRARIES PNG::PNG JPEG::JPEG ${STEAM_ARTWORK_WEBP_LIBRARY})
    set(STEAM_ARTWORK_TEST_DEFINITIONS VIBEPOLLO_STEAM_ARTWORK_IMAGE_LIBS=1)
    set(STEAM_ARTWORK_TEST_LIBRARIES PNG::PNG JPEG::JPEG ${STEAM_ARTWORK_WEBP_LIBRARY})
endif()
list(APPEND SUNSHINE_DEFINITIONS SUNSHINE_STEAM_ARTWORK_NETWORK=1)

include_directories(
        BEFORE
        SYSTEM
        "${CMAKE_SOURCE_DIR}/third-party"
        "${CMAKE_SOURCE_DIR}/third-party/moonlight-common-c/enet/include"
        "${CMAKE_SOURCE_DIR}/third-party/nanors"
        "${CMAKE_SOURCE_DIR}/third-party/nanors/deps/obl"
        ${SQLITE3_INCLUDE_DIRS}
        # BEFORE prepends these one at a time, so later entries are searched first. Keep OpenSSL
        # and pinned FFmpeg after Opus: on macOS Opus resolves to Homebrew's shared include directory,
        # which may hold another OpenSSL's or FFmpeg's headers than the pinned libraries.
        ${Opus_INCLUDE_DIR}
        ${SUNSHINE_FFMPEG_INCLUDE_DIRS}
        ${OPENSSL_INCLUDE_DIR}
        ${Boost_INCLUDE_DIRS}  # has to be the last, or we get runtime error on macOS ffmpeg encoder
)

list(APPEND SUNSHINE_EXTERNAL_LIBRARIES
        ${MINIUPNP_LIBRARIES}
        ${CMAKE_THREAD_LIBS_INIT}
        ${SQLITE3_LIBRARIES}
        enet
        libdisplaydevice::display_device
        nlohmann_json::nlohmann_json
        ${Opus_LIBRARY}
        ${FFMPEG_LIBRARIES}
        ${Boost_LIBRARIES}
        ${OPENSSL_LIBRARIES}
        ${PLATFORM_LIBRARIES})
