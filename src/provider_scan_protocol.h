/**
 * @file src/provider_scan_protocol.h
 * @brief Bounded protocol for Steam provider catalog serialization.
 */
#pragma once

#include "steam_integration.h"

#include <chrono>
#include <cstddef>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace platf::provider_scan {
  inline constexpr std::string_view schema_name = "vibeshine.provider-catalog";
  inline constexpr unsigned int schema_version = 1;
  inline constexpr std::size_t max_games = 4096;
  inline constexpr std::size_t max_payload_bytes = 16U * 1024U * 1024U;
  inline constexpr auto command_timeout = std::chrono::seconds {15};

  struct steam_catalog_t {
    bool available = false;
    std::vector<steam::game_t> games;
  };

  std::optional<std::string> encode_steam_catalog(const steam_catalog_t &catalog);
  std::optional<steam_catalog_t> decode_steam_catalog(std::string_view payload);
}  // namespace platf::provider_scan
