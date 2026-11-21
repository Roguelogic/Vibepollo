cmake_minimum_required(VERSION 3.20)

# Standalone macOS test suite for Vibepollo.
project(VibepolloTests LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(SUNSHINE_TEST_REPOSITORY_ROOT "${CMAKE_CURRENT_LIST_DIR}/..")

set(SUNSHINE_TEST_FFMPEG_PLATFORM_LIBRARIES "")
if(WIN32)
    list(APPEND SUNSHINE_TEST_FFMPEG_PLATFORM_LIBRARIES bcrypt)
elseif(APPLE)
    # FFmpeg's static archives include the VideoToolbox encoder and hardware context.
    list(APPEND SUNSHINE_TEST_FFMPEG_PLATFORM_LIBRARIES
        "-framework CoreFoundation"
        "-framework CoreMedia"
        "-framework CoreVideo"
        "-framework VideoToolbox"
        "-framework AudioToolbox")
endif()

# Test categories make the dependency scope of a target visible at configuration
# time. Every target must declare the smallest sources and libraries that
# preserve the behavior it exercises.
option(SUNSHINE_TEST_ENABLE_FAST "Configure fast, self-contained test targets" ON)
option(SUNSHINE_TEST_ENABLE_COMPONENT "Configure narrowly scoped component test targets" ON)

include("${CMAKE_CURRENT_LIST_DIR}/cmake/SunshineTestTargets.cmake")

set(SUNSHINE_TEST_GTEST_SOURCE_DIR "" CACHE PATH
    "Optional GoogleTest source tree for an isolated test worktree")
if(SUNSHINE_TEST_GTEST_SOURCE_DIR)
    set(GTEST_SOURCE_DIR "${SUNSHINE_TEST_GTEST_SOURCE_DIR}")
else()
    set(GTEST_SOURCE_DIR "${SUNSHINE_TEST_REPOSITORY_ROOT}/third-party/googletest")
endif()
if(NOT EXISTS "${GTEST_SOURCE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
        "GoogleTest is required for the test configuration. "
        "Initialize third-party/googletest before configuring tests.")
endif()

set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
set(INSTALL_GMOCK OFF CACHE BOOL "" FORCE)
add_subdirectory("${GTEST_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/googletest")

if(NOT TARGET nlohmann_json::nlohmann_json)
    include("${SUNSHINE_TEST_REPOSITORY_ROOT}/cmake/dependencies/nlohmann_json.cmake")
endif()

find_package(PkgConfig REQUIRED)
pkg_check_modules(SQLITE3 REQUIRED IMPORTED_TARGET sqlite3)
find_package(Threads REQUIRED)
find_package(OpenSSL REQUIRED)
find_package(ZLIB REQUIRED)
find_package(Python3 COMPONENTS Interpreter)

set(_sunshine_test_boost_components
    algorithm
    asio
    crc
    filesystem
    format
    function
    log
    log_setup
    process
    program_options
    property_tree
    regex
    system
    uuid)
set(_sunshine_test_missing_boost_target FALSE)
foreach(_sunshine_test_boost_component IN LISTS _sunshine_test_boost_components)
    if(NOT TARGET "Boost::${_sunshine_test_boost_component}")
        set(_sunshine_test_missing_boost_target TRUE)
        break()
    endif()
endforeach()
if(_sunshine_test_missing_boost_target)
    find_package(Boost CONFIG REQUIRED COMPONENTS ${_sunshine_test_boost_components})
endif()

add_library(sunshine_test_simple_web_headers INTERFACE)
target_include_directories(sunshine_test_simple_web_headers SYSTEM INTERFACE
    "${SUNSHINE_TEST_REPOSITORY_ROOT}/third-party")
target_link_libraries(sunshine_test_simple_web_headers INTERFACE
    Boost::asio OpenSSL::SSL OpenSSL::Crypto)

add_library(sunshine_test_moonlight_headers INTERFACE)
target_include_directories(sunshine_test_moonlight_headers SYSTEM INTERFACE
    "${SUNSHINE_TEST_REPOSITORY_ROOT}/third-party")

add_library(sunshine_test_nanors_headers INTERFACE)
target_include_directories(sunshine_test_nanors_headers SYSTEM INTERFACE
    "${SUNSHINE_TEST_REPOSITORY_ROOT}/third-party/nanors"
    "${SUNSHINE_TEST_REPOSITORY_ROOT}/third-party/nanors/deps/obl")

enable_testing()

function(sunshine_register_component)
    cmake_parse_arguments(COMPONENT "" "NAME;TEST_SOURCE" "EXTRA_TEST_SOURCES;SUPPORT_SOURCES;PRODUCT_SOURCES;INCLUDE_DIRECTORIES;LINK_LIBRARIES;DEFINITIONS" ${ARGN})
    sunshine_add_test_target(
        NAME "${COMPONENT_NAME}"
        CATEGORY component
        TEST_SOURCES
            "${CMAKE_CURRENT_LIST_DIR}/tests_main.cpp"
            "${CMAKE_CURRENT_LIST_DIR}/${COMPONENT_TEST_SOURCE}"
            ${COMPONENT_EXTRA_TEST_SOURCES}
        SUPPORT_SOURCES ${COMPONENT_SUPPORT_SOURCES}
        PRODUCT_SOURCES ${COMPONENT_PRODUCT_SOURCES}
        INCLUDE_DIRECTORIES ${COMPONENT_INCLUDE_DIRECTORIES}
        DEFINITIONS SUNSHINE_TESTS ${COMPONENT_DEFINITIONS}
        LINK_LIBRARIES GTest::gtest ${COMPONENT_LINK_LIBRARIES}
        DEPENDENCIES
    )
endfunction()

# --- Fast self-contained tests ---
sunshine_add_test_target(
    NAME test_fast_foundation
    CATEGORY fast
    TEST_SOURCES "${CMAKE_CURRENT_LIST_DIR}/tests_main.cpp"
    LINK_LIBRARIES GTest::gtest
)

sunshine_add_test_target(
    NAME test_fast_thread_safe
    CATEGORY fast
    TEST_SOURCES
        "${CMAKE_CURRENT_LIST_DIR}/tests_main.cpp"
        "${CMAKE_CURRENT_LIST_DIR}/unit/test_thread_safe.cpp"
    LINK_LIBRARIES GTest::gtest nlohmann_json::nlohmann_json
)

sunshine_add_test_target(
    NAME test_fast_update_release
    CATEGORY fast
    TEST_SOURCES unit/test_update_release_standalone.cpp
    LINK_LIBRARIES nlohmann_json::nlohmann_json
)

sunshine_add_test_target(
    NAME test_fast_legacy_nightly_update
    CATEGORY fast
    TEST_SOURCES unit/test_legacy_nightly_update_standalone.cpp
    LINK_LIBRARIES nlohmann_json::nlohmann_json
)

sunshine_add_test_target(
    NAME test_fast_version_compare
    CATEGORY fast
    TEST_SOURCES
        "${CMAKE_CURRENT_LIST_DIR}/tests_main.cpp"
        "${CMAKE_CURRENT_LIST_DIR}/unit/test_version_compare.cpp"
    LINK_LIBRARIES GTest::gtest
)

sunshine_add_test_target(
    NAME test_fast_framegen_policy
    CATEGORY fast
    TEST_SOURCES
        "${CMAKE_CURRENT_LIST_DIR}/tests_main.cpp"
        "${CMAKE_CURRENT_LIST_DIR}/unit/test_framegen_policy.cpp"
    LINK_LIBRARIES GTest::gtest
)

set_source_files_properties(
    "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/rswrapper.c"
    PROPERTIES COMPILE_OPTIONS "-ftree-vectorize;-funroll-loops"
)
sunshine_add_test_target(
    NAME test_fast_rswrapper
    CATEGORY fast
    TEST_SOURCES
        "${CMAKE_CURRENT_LIST_DIR}/tests_main.cpp"
        "${CMAKE_CURRENT_LIST_DIR}/unit/test_rswrapper.cpp"
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/rswrapper.c"
    LINK_LIBRARIES GTest::gtest sunshine_test_nanors_headers
)

# --- Component C++ tests ---
sunshine_add_test_target(
    NAME test_component_crypto_compat
    CATEGORY component
    TEST_SOURCES unit/test_crypto_compat.cpp
    LINK_LIBRARIES OpenSSL::Crypto nlohmann_json::nlohmann_json
)

sunshine_add_test_target(
    NAME test_component_update_notification_state
    CATEGORY component
    TEST_SOURCES unit/test_update_notification_state_standalone.cpp
    LINK_LIBRARIES Boost::property_tree nlohmann_json::nlohmann_json
)

foreach(_assert_test IN ITEMS test_fast_update_release test_fast_legacy_nightly_update test_component_update_notification_state)
    if(TARGET ${_assert_test})
        target_compile_options(${_assert_test} PRIVATE -UNDEBUG)
    endif()
endforeach()

if(SUNSHINE_TEST_ENABLE_COMPONENT)
    add_subdirectory(process_catalog)
endif()

sunshine_add_test_target(
    NAME test_component_broadcast_runtime
    CATEGORY component
    TEST_SOURCES
        "${CMAKE_CURRENT_LIST_DIR}/tests_main.cpp"
        "${CMAKE_CURRENT_LIST_DIR}/unit/test_broadcast_runtime.cpp"
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/stream_broadcast_runtime.cpp"
    LINK_LIBRARIES GTest::gtest Threads::Threads nlohmann_json::nlohmann_json
)

sunshine_add_test_target(
    NAME test_component_nvhttp_dispatch
    CATEGORY component
    TEST_SOURCES
        "${CMAKE_CURRENT_LIST_DIR}/tests_main.cpp"
        "${CMAKE_CURRENT_LIST_DIR}/unit/test_nvhttp_dispatch.cpp"
    PRODUCT_SOURCES
        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/stream_broadcast_runtime.cpp"
        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/http_pairing_policy.cpp"
    LINK_LIBRARIES GTest::gtest Threads::Threads nlohmann_json::nlohmann_json Boost::property_tree
)

sunshine_add_test_target(
    NAME test_component_nvhttp_bitrate_policy
    CATEGORY component
    TEST_SOURCES
        "${CMAKE_CURRENT_LIST_DIR}/tests_main.cpp"
        "${CMAKE_CURRENT_LIST_DIR}/unit/test_nvhttp_bitrate_policy.cpp"
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/stream_broadcast_runtime.cpp"
    LINK_LIBRARIES GTest::gtest Threads::Threads nlohmann_json::nlohmann_json Boost::property_tree OpenSSL::Crypto
)

sunshine_add_test_target(
    NAME test_component_stream_start_dispatch
    CATEGORY component
    TEST_SOURCES
        "${CMAKE_CURRENT_LIST_DIR}/tests_main.cpp"
        "${CMAKE_CURRENT_LIST_DIR}/unit/test_stream_start_dispatch.cpp"
    LINK_LIBRARIES GTest::gtest Threads::Threads Boost::property_tree
)

sunshine_add_test_target(
    NAME test_component_audio_snapshot
    CATEGORY component
    TEST_SOURCES "${CMAKE_CURRENT_LIST_DIR}/unit/test_audio_context.cpp"
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/audio_context.cpp"
    LINK_LIBRARIES Threads::Threads nlohmann_json::nlohmann_json
)
if(TARGET test_component_audio_snapshot)
    add_test(NAME test_component_audio_display_snapshot COMMAND test_component_audio_snapshot context.)
    add_test(NAME test_component_audio_display_transition COMMAND test_component_audio_snapshot transition.)
    set_tests_properties(test_component_audio_display_snapshot test_component_audio_display_transition
        PROPERTIES LABELS "component" TIMEOUT 30)
endif()

sunshine_register_component(NAME test_component_stream_protocol TEST_SOURCE unit/test_stream.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/stream_protocol.cpp")
sunshine_register_component(NAME test_component_video_pacing TEST_SOURCE unit/test_video_pacing.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/stream_protocol.cpp")
sunshine_register_component(NAME test_component_remote_session TEST_SOURCE unit/test_remote_session.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/remote_session.cpp"
    LINK_LIBRARIES nlohmann_json::nlohmann_json)
sunshine_register_component(NAME test_component_rtsp_pending_policy TEST_SOURCE unit/test_rtsp_pending_policy.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/rtsp_pending_policy.cpp")
sunshine_register_component(NAME test_component_pyrowave_udp_probe TEST_SOURCE unit/test_pyrowave_udp_probe.cpp
    LINK_LIBRARIES Boost::asio Boost::system)
sunshine_register_component(NAME test_component_pyrowave_policy TEST_SOURCE unit/test_pyrowave_policy.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/pyrowave_policy.cpp")
sunshine_register_component(NAME test_component_hdr_request_policy TEST_SOURCE unit/test_hdr_request_policy.cpp)
sunshine_register_component(NAME test_component_single_flight TEST_SOURCE unit/test_single_flight.cpp)
sunshine_register_component(NAME test_component_paused_app_monitor TEST_SOURCE unit/test_paused_app_monitor.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/power_action.cpp"
    LINK_LIBRARIES Threads::Threads Boost::property_tree OpenSSL::Crypto)
sunshine_register_component(NAME test_component_config_parse TEST_SOURCE unit/test_config_parse.cpp)
sunshine_register_component(NAME test_component_managed_app_focus TEST_SOURCE unit/test_managed_app_focus.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/managed_app_focus.cpp"
                    "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/steam_process_tracker.cpp")

sunshine_register_component(NAME test_component_steam_integration TEST_SOURCE test_steam_integration.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/steam_integration.cpp"
                    "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/provider_scan_protocol.cpp"
    LINK_LIBRARIES nlohmann_json::nlohmann_json)
if(FFMPEG_LIBRARIES)
    sunshine_register_component(NAME test_component_steam_artwork TEST_SOURCE test_steam_artwork.cpp
        PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/steam_artwork.cpp"
                        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/steam_integration.cpp"
                        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/provider_scan_protocol.cpp"
        INCLUDE_DIRECTORIES ${FFMPEG_INCLUDE_DIRS}
        LINK_LIBRARIES nlohmann_json::nlohmann_json ${FFMPEG_LIBRARIES} ${STEAM_ARTWORK_TEST_LIBRARIES}
                       ${SUNSHINE_TEST_FFMPEG_PLATFORM_LIBRARIES}
        DEFINITIONS ${STEAM_ARTWORK_TEST_DEFINITIONS})
    sunshine_register_component(NAME test_component_video_colorspace TEST_SOURCE unit/test_video_colorspace.cpp
        PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/video_colorspace.cpp"
                        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/logging.cpp"
                        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/logging_policy.cpp"
        INCLUDE_DIRECTORIES ${FFMPEG_INCLUDE_DIRS}
        LINK_LIBRARIES nlohmann_json::nlohmann_json Boost::log Boost::asio Boost::crc Boost::format Boost::process ZLIB::ZLIB
                       ${FFMPEG_LIBRARIES} ${SUNSHINE_TEST_FFMPEG_PLATFORM_LIBRARIES})
endif()
sunshine_register_component(NAME test_component_config_steam TEST_SOURCE test_config_steam.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/config_steam.cpp"
    LINK_LIBRARIES nlohmann_json::nlohmann_json)
sunshine_register_component(NAME test_component_steam_sync TEST_SOURCE test_steam_sync.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/steam_sync_policy.cpp"
                    "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/steam_integration.cpp"
                    "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/provider_scan_protocol.cpp"
    LINK_LIBRARIES nlohmann_json::nlohmann_json)
sunshine_register_component(NAME test_component_steam_process_tracker TEST_SOURCE test_steam_process_tracker.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/steam_process_tracker.cpp")
sunshine_register_component(NAME test_component_steam_auto_sync TEST_SOURCE test_steam_auto_sync.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/steam_auto_sync_policy.cpp"
                    "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/steam_integration.cpp"
                    "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/provider_scan_protocol.cpp"
    LINK_LIBRARIES nlohmann_json::nlohmann_json)
sunshine_register_component(NAME test_component_provider_scan_protocol TEST_SOURCE test_provider_scan_protocol.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/provider_scan_protocol.cpp"
    LINK_LIBRARIES nlohmann_json::nlohmann_json)

sunshine_register_component(NAME test_component_file_handler TEST_SOURCE unit/test_file_handler.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/file_handler_core.cpp")
sunshine_register_component(NAME test_component_state_storage TEST_SOURCE unit/test_state_storage.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/state_storage_policy.cpp"
    LINK_LIBRARIES Boost::property_tree nlohmann_json::nlohmann_json)
sunshine_register_component(NAME test_component_shutdown_phase TEST_SOURCE unit/test_shutdown_phase.cpp)
sunshine_register_component(NAME test_component_pairing_recovery TEST_SOURCE unit/test_pairing_recovery.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/pairing_recovery.cpp"
                    "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/state_storage_policy.cpp"
                    "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/crypto.cpp"
                    "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/http_pairing_policy.cpp"
    LINK_LIBRARIES Boost::property_tree nlohmann_json::nlohmann_json OpenSSL::Crypto)
sunshine_register_component(NAME test_component_virtual_display_scale TEST_SOURCE unit/test_virtual_display_scale.cpp)
sunshine_register_component(NAME test_component_color_profile_policy TEST_SOURCE unit/test_color_profile_policy.cpp)

sunshine_register_component(NAME test_component_http_auth TEST_SOURCE unit/test_http_auth.cpp
    EXTRA_TEST_SOURCES "${CMAKE_CURRENT_LIST_DIR}/unit/test_confighttp.cpp"
    PRODUCT_SOURCES
        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/http_auth_policy.cpp"
        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/http_auth_request_policy.cpp"
        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/config_http_policy.cpp"
    LINK_LIBRARIES GTest::gmock nlohmann_json::nlohmann_json sunshine_test_simple_web_headers
        Boost::algorithm Boost::function Boost::property_tree)
sunshine_register_component(NAME test_component_http_policy TEST_SOURCE unit/test_httpcommon.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/http_policy.cpp"
    LINK_LIBRARIES Boost::property_tree)
sunshine_register_component(NAME test_component_https_listener_diagnostics
    TEST_SOURCE unit/test_https_listener_diagnostics.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/http_auth_request_policy.cpp"
    LINK_LIBRARIES nlohmann_json::nlohmann_json sunshine_test_simple_web_headers
        Boost::algorithm Boost::function Boost::property_tree)
sunshine_register_component(NAME test_component_network_policy TEST_SOURCE unit/test_network.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/network_policy.cpp"
    LINK_LIBRARIES Boost::algorithm Boost::asio)
sunshine_register_component(NAME test_component_input_validation TEST_SOURCE unit/test_input.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/input_validation_policy.cpp"
    LINK_LIBRARIES sunshine_test_moonlight_headers)
sunshine_register_component(NAME test_component_process_policy TEST_SOURCE unit/test_process.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/app_catalog_policy.cpp"
                    "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/remote_session.cpp"
    LINK_LIBRARIES Boost::crc nlohmann_json::nlohmann_json)
sunshine_register_component(NAME test_component_builtin_virtual_display TEST_SOURCE unit/test_builtin_virtual_display.cpp
    INCLUDE_DIRECTORIES "${OPENSSL_INCLUDE_DIR}"
    LINK_LIBRARIES nlohmann_json::nlohmann_json Boost::process Boost::log Boost::format sunshine_test_moonlight_headers)
sunshine_register_component(NAME test_component_process_framegen_json TEST_SOURCE unit/test_process_framegen_json.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/app_framegen_config.cpp"
    LINK_LIBRARIES nlohmann_json::nlohmann_json)
sunshine_register_component(NAME test_component_session_history TEST_SOURCE unit/test_session_history.cpp
    PRODUCT_SOURCES
        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/session_history_storage.cpp"
        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/session_history_storage_diagnostics.cpp"
        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/session_history_policy.cpp"
    LINK_LIBRARIES PkgConfig::SQLITE3 nlohmann_json::nlohmann_json)
sunshine_register_component(NAME test_component_hardware_metrics TEST_SOURCE unit/test_hardware_metrics.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/hardware_metrics.cpp"
    LINK_LIBRARIES nlohmann_json::nlohmann_json)
sunshine_register_component(NAME test_component_host_stats TEST_SOURCE unit/test_host_stats.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/host_stats_service.cpp")
sunshine_register_component(NAME test_component_audio_policy TEST_SOURCE unit/test_audio.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/audio_policy.cpp")
sunshine_register_component(NAME test_component_mouse_policy TEST_SOURCE unit/test_mouse.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/mouse_input.cpp")
sunshine_register_component(NAME test_component_platform_common TEST_SOURCE unit/platform/test_common.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/platform/common_services.cpp")

sunshine_register_component(NAME test_component_log_export_sanitizer TEST_SOURCE unit/test_log_export_sanitizer.cpp
    LINK_LIBRARIES Boost::asio Boost::crc Boost::regex ZLIB::ZLIB)
sunshine_register_component(NAME test_component_log_export_reader TEST_SOURCE unit/test_log_export_reader.cpp
    LINK_LIBRARIES Boost::asio Boost::crc Boost::regex ZLIB::ZLIB)
sunshine_register_component(NAME test_component_log_sessions TEST_SOURCE unit/test_log_sessions.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/logging.cpp"
                    "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/logging_policy.cpp"
    LINK_LIBRARIES Boost::log Boost::asio Boost::crc Boost::format Boost::regex ZLIB::ZLIB)
sunshine_register_component(NAME test_component_logging_policy TEST_SOURCE unit/test_logging.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/logging_policy.cpp")
sunshine_register_component(NAME test_component_entry_metadata TEST_SOURCE unit/test_entry_handler.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/entry_metadata.cpp")
sunshine_register_component(NAME test_component_entry_credentials TEST_SOURCE unit/test_entry_credentials.cpp)
sunshine_register_component(NAME test_component_config_http_policy TEST_SOURCE unit/test_config_http_policy.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/config_http_policy.cpp"
    LINK_LIBRARIES Boost::asio Boost::system)
sunshine_register_component(NAME test_component_http_pairing_policy TEST_SOURCE unit/test_http_pairing.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/http_pairing_policy.cpp"
                    "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/state_storage_policy.cpp"
    LINK_LIBRARIES nlohmann_json::nlohmann_json Boost::property_tree)
sunshine_register_component(NAME test_component_tls_client_identity TEST_SOURCE unit/test_tls_client_identity.cpp
    PRODUCT_SOURCES
        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/tls_client_identity.cpp"
        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/tls_client_identity_native.cpp"
        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/http_pairing_policy.cpp"
        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/crypto.cpp"
    LINK_LIBRARIES nlohmann_json::nlohmann_json sunshine_test_simple_web_headers)
sunshine_register_component(NAME test_component_power_action TEST_SOURCE unit/test_power_action.cpp
    PRODUCT_SOURCES
        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/power_action.cpp"
        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/tls_client_identity.cpp"
        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/http_pairing_policy.cpp"
        "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/crypto.cpp"
    LINK_LIBRARIES nlohmann_json::nlohmann_json sunshine_test_simple_web_headers Boost::property_tree)
sunshine_register_component(NAME test_component_power_action_native
    TEST_SOURCE unit/test_power_action_native.cpp
    INCLUDE_DIRECTORIES "${CMAKE_CURRENT_LIST_DIR}/support/power_api")
sunshine_register_component(NAME test_component_power_action_native_legacy_headers
    TEST_SOURCE unit/test_power_action_native.cpp
    INCLUDE_DIRECTORIES "${CMAKE_CURRENT_LIST_DIR}/support/power_api"
    DEFINITIONS SUNSHINE_TEST_LEGACY_POWER_CAPABILITIES)

sunshine_register_component(NAME test_component_video_policy TEST_SOURCE unit/test_video.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/video_policy.cpp"
    LINK_LIBRARIES nlohmann_json::nlohmann_json)
sunshine_register_component(NAME test_component_video_capture_source TEST_SOURCE unit/test_video_capture_source.cpp
    PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/video_policy.cpp"
    LINK_LIBRARIES nlohmann_json::nlohmann_json)
sunshine_register_component(NAME test_component_screen_saver_state TEST_SOURCE unit/test_screen_saver_state.cpp
    LINK_LIBRARIES nlohmann_json::nlohmann_json)
sunshine_register_component(NAME test_component_video_adaptive_pacing TEST_SOURCE unit/test_video_adaptive_pacing.cpp)
sunshine_register_component(NAME test_component_video_fec_status TEST_SOURCE unit/test_video_fec_status.cpp)
sunshine_register_component(NAME test_component_encoder_probe_policy TEST_SOURCE unit/test_encoder_probe_policy.cpp)

sunshine_register_component(NAME test_component_resource_locale_catalog TEST_SOURCE integration/test_locale_consistency.cpp
    SUPPORT_SOURCES "${CMAKE_CURRENT_LIST_DIR}/support/file_handler_read_only.cpp"
    LINK_LIBRARIES nlohmann_json::nlohmann_json)
if(TARGET test_component_resource_locale_catalog)
    set_tests_properties(test_component_resource_locale_catalog PROPERTIES
        WORKING_DIRECTORY "${SUNSHINE_TEST_REPOSITORY_ROOT}")
endif()
sunshine_register_component(NAME test_component_external_command_policy TEST_SOURCE integration/test_external_commands.cpp)
sunshine_register_component(NAME test_component_capture_recovery TEST_SOURCE unit/test_capture_recovery.cpp)
sunshine_register_component(NAME test_component_controller_speaker_pcm TEST_SOURCE unit/test_controller_speaker_pcm.cpp)
sunshine_register_component(NAME test_component_utility_hex TEST_SOURCE unit/test_utility_hex.cpp
    LINK_LIBRARIES nlohmann_json::nlohmann_json)
sunshine_register_component(NAME test_component_round_robin TEST_SOURCE unit/test_round_robin.cpp)
sunshine_register_component(NAME test_component_stat_tracker_bounds TEST_SOURCE unit/test_stat_tracker_bounds.cpp
    LINK_LIBRARIES Boost::format)

# --- macOS native component tests ---
if(APPLE)
    set_source_files_properties(
        "${CMAKE_CURRENT_LIST_DIR}/unit/platform/macos/test_av_audio.mm"
        PROPERTIES LANGUAGE CXX)
    sunshine_register_component(NAME test_component_av_audio_policy TEST_SOURCE unit/platform/macos/test_av_audio.mm
        PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/platform/macos/av_audio_policy.cpp")
    sunshine_register_component(NAME test_component_macos_wheel_scroll TEST_SOURCE unit/platform/macos/test_wheel_scroll.cpp)
    sunshine_register_component(NAME test_component_macos_window_drag_prefetch TEST_SOURCE unit/platform/macos/test_window_drag_prefetch.cpp
        LINK_LIBRARIES Threads::Threads)
    sunshine_register_component(NAME test_component_macos_display_policy TEST_SOURCE unit/platform/macos/test_display_policy.cpp
        PRODUCT_SOURCES "${SUNSHINE_TEST_REPOSITORY_ROOT}/src/platform/macos/display_policy.cpp")
endif()

# --- Python component & macOS regression tests ---
if(Python3_Interpreter_FOUND AND SUNSHINE_TEST_ENABLE_COMPONENT)
    add_test(NAME test_component_dolby_session_isolation
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_LIST_DIR}/unit/test_dolby_session_isolation.py"
            "${SUNSHINE_TEST_REPOSITORY_ROOT}" "${CMAKE_CXX_COMPILER}")
    set_tests_properties(test_component_dolby_session_isolation PROPERTIES LABELS "component" TIMEOUT 30)

    add_test(NAME test_component_ffmpeg_package_pin
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_LIST_DIR}/unit/test_ffmpeg_package_pin.py")
    set_tests_properties(test_component_ffmpeg_package_pin PROPERTIES LABELS "component" TIMEOUT 60)

    add_test(NAME test_component_control_peer_timeout
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_LIST_DIR}/unit/test_control_peer_timeout.py"
            "${SUNSHINE_TEST_REPOSITORY_ROOT}" "${CMAKE_CXX_COMPILER}")
    set_tests_properties(test_component_control_peer_timeout PROPERTIES LABELS "component" TIMEOUT 30)

    add_test(NAME test_component_hardware_metrics_config
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_LIST_DIR}/unit/test_hardware_metrics_config.py"
            "${SUNSHINE_TEST_REPOSITORY_ROOT}" "${CMAKE_CXX_COMPILER}")
    set_tests_properties(test_component_hardware_metrics_config PROPERTIES LABELS "component" TIMEOUT 30)

    add_test(NAME test_component_upnp_igd_status
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_LIST_DIR}/unit/test_upnp_igd_status.py"
            --compiler "${CMAKE_CXX_COMPILER}")
    set_tests_properties(test_component_upnp_igd_status PROPERTIES LABELS "component" TIMEOUT 60)

    add_test(NAME test_component_update_notification_tray_interface
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_LIST_DIR}/unit/test_update_notification_tray_interface.py"
            "${SUNSHINE_TEST_REPOSITORY_ROOT}" "${CMAKE_CXX_COMPILER}")
    set_tests_properties(test_component_update_notification_tray_interface PROPERTIES LABELS "component" TIMEOUT 60)

    add_test(NAME test_component_common_assets
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_LIST_DIR}/integration/test_common_assets.py"
            --repository "${SUNSHINE_TEST_REPOSITORY_ROOT}" --cmake "${CMAKE_COMMAND}")
    set_tests_properties(test_component_common_assets PROPERTIES LABELS "component;packaging" TIMEOUT 60)

    add_test(NAME regression_shutdown_deadline
        COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_LIST_DIR}/unit/test_shutdown_deadline.py"
            --compiler "${CMAKE_CXX_COMPILER}")
    set_tests_properties(regression_shutdown_deadline PROPERTIES LABELS "component" TIMEOUT 30)

    add_test(NAME regression_boost_locale_source_group
        COMMAND "${CMAKE_COMMAND}" -E env "CMAKE_COMMAND=${CMAKE_COMMAND}"
            "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_LIST_DIR}/unit/test_boost_locale_patch.py")
    set_tests_properties(regression_boost_locale_source_group PROPERTIES LABELS "component" TIMEOUT 30)

    add_test(NAME test_component_videotoolbox_options
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_LIST_DIR}/unit/test_older_native_fixes.py"
            --repo "${SUNSHINE_TEST_REPOSITORY_ROOT}" --compiler "${CMAKE_CXX_COMPILER}"
            --only videotoolbox)
    set_tests_properties(test_component_videotoolbox_options PROPERTIES LABELS "component" TIMEOUT 60)

    add_test(NAME test_component_macos_launch_role
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_LIST_DIR}/unit/test_macos_launch_role.py"
            --compiler "${CMAKE_CXX_COMPILER}")
    set_tests_properties(test_component_macos_launch_role PROPERTIES LABELS "component" TIMEOUT 60)

    add_test(NAME regression_macos_link_dependencies
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_LIST_DIR}/unit/platform/macos/test_link_dependencies.py"
            --cmake "${CMAKE_COMMAND}")
    set_tests_properties(regression_macos_link_dependencies PROPERTIES LABELS "component" TIMEOUT 60)

    add_test(NAME regression_file_clock_compatibility
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_LIST_DIR}/unit/platform/macos/test_file_clock_compatibility.py"
            --compiler "${CMAKE_CXX_COMPILER}")
    set_tests_properties(regression_file_clock_compatibility PROPERTIES LABELS "component" TIMEOUT 60)

    add_library(sunshine_test_macos_build_api_dependencies INTERFACE)
    target_link_libraries(sunshine_test_macos_build_api_dependencies INTERFACE
        Boost::process Boost::program_options Boost::filesystem Boost::algorithm)
    add_test(NAME regression_macos_build_api_compatibility
        COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_LIST_DIR}/unit/platform/macos/test_build_api_compatibility.py"
            --compiler "${CMAKE_CXX_COMPILER}"
            --process-library "$<TARGET_FILE:Boost::process>"
            --include-dir "$<TARGET_PROPERTY:sunshine_test_macos_build_api_dependencies,INTERFACE_INCLUDE_DIRECTORIES>")
    set_tests_properties(regression_macos_build_api_compatibility PROPERTIES LABELS "component" TIMEOUT 60)
endif()
