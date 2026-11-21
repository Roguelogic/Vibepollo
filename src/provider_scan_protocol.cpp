/**
 * @file src/provider_scan_protocol.cpp
 * @brief Bounded protocol for Steam provider catalog serialization.
 */
#include "file_clock.h"
#include "provider_scan_protocol.h"

#include <algorithm>
#include <cstdint>
#include <nlohmann/json.hpp>
#include <set>
#include <system_error>

namespace fs = std::filesystem;

namespace platf::provider_scan {
  namespace {
    using json = nlohmann::json;

    constexpr std::size_t max_name_bytes = 512;
    constexpr std::size_t max_label_bytes = 128;

    bool safe_text(const std::string &value, std::size_t maximum, bool allow_empty = true) {
      if ((!allow_empty && value.empty()) || value.size() > maximum) return false;
      return std::none_of(value.begin(), value.end(), [](unsigned char character) {
        return character < 0x20 || character == 0x7f;
      });
    }

    template<typename T>
    bool exact_keys(const json &value, std::initializer_list<T> expected) {
      if (!value.is_object() || value.size() != expected.size()) return false;
      return std::all_of(expected.begin(), expected.end(), [&](const auto *key) {
        return value.contains(key);
      });
    }

    bool unsigned_number(const json &value, std::uint64_t &result) {
      if (!value.is_number_unsigned()) return false;
      result = value.get<std::uint64_t>();
      return true;
    }

    bool safe_string_field(const json &object, const char *key, std::string &result,
                           std::size_t maximum, bool allow_empty = true) {
      const auto &value = object.at(key);
      if (!value.is_string()) return false;
      result = value.get<std::string>();
      return safe_text(result, maximum, allow_empty);
    }

    bool valid_header(const json &root, std::string_view provider) {
      return root.at("schema").is_string() && root.at("schema").get<std::string>() == schema_name &&
             root.at("version").is_number_unsigned() && root.at("version").get<std::uint64_t>() == schema_version &&
             root.at("provider").is_string() && root.at("provider").get<std::string>() == provider &&
             root.at("games").is_array() && root.at("games").size() <= max_games;
    }

    std::string artwork_revision(std::initializer_list<fs::path> paths) {
      std::uint64_t hash = 1469598103934665603ULL;
      bool found = false;
      for (const auto &path : paths) {
        std::error_code ec;
        if (path.empty() || !fs::is_regular_file(path, ec)) continue;
        const auto size = fs::file_size(path, ec);
        if (ec) continue;
        const auto time = fs::last_write_time(path, ec);
        if (ec) continue;
        found = true;
        const auto value = path.generic_string() + ":" + std::to_string(size) + ":" +
                           file_clock::count_string(time.time_since_epoch().count());
        for (const unsigned char byte : value) hash = (hash ^ byte) * 1099511628211ULL;
      }
      return found ? std::to_string(hash) : std::string {};
    }

    bool decode_artwork_revision(const json &entry, std::string &revision) {
      if (!entry.is_object()) return false;
      if (!entry.contains("artwork_revision")) return true;
      if (!safe_string_field(entry, "artwork_revision", revision, 20)) return false;
      return std::all_of(revision.begin(), revision.end(), [](unsigned char c) { return c >= '0' && c <= '9'; });
    }

    json steam_game_json(const steam::game_t &game) {
      return {
        {"app_id", game.app_id},
        {"artwork_revision", artwork_revision({game.artwork_path, game.boxart_path, game.icon_path})},
        {"name", game.name},
        {"app_type", game.app_type},
        {"installed", game.installed},
        {"last_played", game.last_played},
        {"playtime_minutes", game.playtime_minutes},
        {"state_flags", game.state_flags},
        {"last_updated", game.last_updated},
      };
    }

    std::optional<json> parse_payload(std::string_view payload) {
      if (payload.empty() || payload.size() > max_payload_bytes) return std::nullopt;
      try {
        return json::parse(payload.begin(), payload.end());
      } catch (const json::exception &) {
        return std::nullopt;
      }
    }

    std::optional<std::string> bounded_dump(const json &root) {
      try {
        auto payload = root.dump();
        if (payload.size() >= max_payload_bytes) return std::nullopt;
        payload.push_back('\n');
        return payload;
      } catch (const json::exception &) {
        return std::nullopt;
      }
    }
  }  // namespace

  std::optional<std::string> encode_steam_catalog(const steam_catalog_t &catalog) {
    if (catalog.games.size() > max_games) return std::nullopt;
    json root {
      {"schema", schema_name},
      {"version", schema_version},
      {"provider", "steam"},
      {"available", catalog.available},
      {"games", json::array()},
    };
    for (const auto &game : catalog.games) root["games"].push_back(steam_game_json(game));
    const auto payload = bounded_dump(root);
    return payload && decode_steam_catalog(*payload) ? payload : std::nullopt;
  }

  std::optional<steam_catalog_t> decode_steam_catalog(std::string_view payload) {
    const auto parsed = parse_payload(payload);
    if (!parsed || !exact_keys(*parsed, {"schema", "version", "provider", "available", "games"}) ||
        !valid_header(*parsed, "steam") || !parsed->at("available").is_boolean()) return std::nullopt;

    steam_catalog_t result;
    result.available = parsed->at("available").get<bool>();
    if (!result.available && !parsed->at("games").empty()) return std::nullopt;
    std::set<std::uint32_t> seen;
    for (auto entry : parsed->at("games")) {
      std::string revision;
      if (!decode_artwork_revision(entry, revision)) return std::nullopt;
      entry.erase("artwork_revision");
      if (!exact_keys(entry, {"app_id", "name", "app_type", "installed",
                              "last_played", "playtime_minutes", "state_flags", "last_updated"})) return std::nullopt;
      steam::game_t game;
      game.session_artwork_revision = revision;
      std::uint64_t number = 0;
      if (!unsigned_number(entry.at("app_id"), number) || number == 0 || number > UINT32_MAX ||
          !seen.insert(static_cast<std::uint32_t>(number)).second) return std::nullopt;
      game.app_id = static_cast<std::uint32_t>(number);
      game.stable_id = "steam:" + std::to_string(game.app_id);
      if (!safe_string_field(entry, "name", game.name, max_name_bytes) ||
          !safe_string_field(entry, "app_type", game.app_type, max_label_bytes) ||
          !entry.at("installed").is_boolean()) return std::nullopt;
      game.installed = entry.at("installed").get<bool>();
      if (!unsigned_number(entry.at("last_played"), game.last_played) ||
          !unsigned_number(entry.at("playtime_minutes"), game.playtime_minutes) ||
          !unsigned_number(entry.at("state_flags"), number) || number > UINT32_MAX) return std::nullopt;
      game.state_flags = static_cast<std::uint32_t>(number);
      if (!unsigned_number(entry.at("last_updated"), game.last_updated)) return std::nullopt;
      result.games.push_back(std::move(game));
    }
    return result;
  }
}  // namespace platf::provider_scan
