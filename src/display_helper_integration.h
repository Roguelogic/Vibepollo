/**
 * @file src/display_helper_integration.h
 * @brief macOS in-process display fallback stubs for display helper integration.
 */
#pragma once

#include <display_device/types.h>
#include <optional>
#include <string>

namespace display_helper_integration {
  inline bool revert(bool = false) {
    return false;
  }

  inline bool export_golden_restore() {
    return false;
  }

  inline bool reset_persistence() {
    return false;
  }

  inline bool suppress_fallback() {
    return false;
  }

  inline std::string enumerate_devices_json(
    [[maybe_unused]] display_device::DeviceEnumerationDetail detail = display_device::DeviceEnumerationDetail::Minimal
  ) {
    return "[]";
  }

  inline std::optional<display_device::EnumeratedDeviceList> enumerate_devices(
    [[maybe_unused]] display_device::DeviceEnumerationDetail detail = display_device::DeviceEnumerationDetail::Minimal
  ) {
    return std::nullopt;
  }
}  // namespace display_helper_integration
