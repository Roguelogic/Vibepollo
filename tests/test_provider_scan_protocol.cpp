#include "src/provider_scan_protocol.h"

#include <chrono>
#include <cstdlib>
#include <gtest/gtest.h>
#include <nlohmann/json.hpp>
#include <string>

namespace {
  using namespace std::chrono_literals;
  using platf::provider_scan::decode_steam_catalog;
  using platf::provider_scan::encode_steam_catalog;
  using platf::provider_scan::steam_catalog_t;

  TEST(ProviderScanProtocol, SteamRoundTripReconstructsOnlySafeMetadata) {
    platf::steam::game_t source;
    source.app_id = 42;
    source.name = "Safe Game";
    source.install_dir = "/games/Safe Game";
    source.library_path = "/games";
    source.app_type = "game";
    source.installed = true;
    source.last_played = 123;
    source.playtime_minutes = 456;
    source.state_flags = 4;
    source.last_updated = 789;
    source.artwork_path = "/home/user/untrusted.jpg";
    source.launch_executable = "/games/Safe Game/game";
    source.launch_arguments = "; touch /root/should-not-run";
    source.launch_options = "%command%; touch /root/should-not-run";

    const auto encoded = encode_steam_catalog({true, {source}});
    ASSERT_TRUE(encoded);
    const auto decoded = decode_steam_catalog(*encoded);
    ASSERT_TRUE(decoded);
    ASSERT_EQ(decoded->games.size(), 1U);
    const auto &game = decoded->games.front();
    EXPECT_TRUE(decoded->available);
    EXPECT_EQ(game.app_id, 42U);
    EXPECT_EQ(game.stable_id, "steam:42");
    EXPECT_TRUE(game.install_dir.empty());
    EXPECT_TRUE(game.library_path.empty());
    EXPECT_TRUE(game.icon_path.empty());
    EXPECT_TRUE(game.header_path.empty());
    EXPECT_TRUE(game.portrait_path.empty());
    EXPECT_TRUE(game.boxart_path.empty());
    EXPECT_TRUE(game.artwork_path.empty());
    EXPECT_TRUE(game.artwork_client_path.empty());
    EXPECT_TRUE(game.launch_executable.empty());
    EXPECT_TRUE(game.launch_working_dir.empty());
    EXPECT_TRUE(game.proton_path.empty());
    EXPECT_TRUE(game.proton_runtime_path.empty());
    EXPECT_TRUE(game.steam_client_path.empty());
    EXPECT_TRUE(game.compatdata_path.empty());
    EXPECT_TRUE(game.launch_arguments.empty());
    EXPECT_TRUE(game.launch_options.empty());
    EXPECT_TRUE(game.launch_os.empty());
  }

  TEST(ProviderScanProtocol, SteamRejectsSchemaDriftDuplicateIdsAndControls) {
    platf::steam::game_t source;
    source.app_id = 7;
    source.name = "Game";
    source.install_dir = "/games/Game";
    source.library_path = "/games";
    source.installed = true;
    const auto encoded = encode_steam_catalog({true, {source}});
    ASSERT_TRUE(encoded);
    auto document = nlohmann::json::parse(*encoded);

    auto unknown = document;
    unknown["unexpected"] = true;
    EXPECT_FALSE(decode_steam_catalog(unknown.dump()));

    auto duplicate = document;
    duplicate["games"].push_back(duplicate["games"].front());
    EXPECT_FALSE(decode_steam_catalog(duplicate.dump()));

    auto injected_path = document;
    injected_path["games"][0]["install_dir"] = "/home/user/game";
    EXPECT_FALSE(decode_steam_catalog(injected_path.dump()));

    auto control = document;
    control["games"][0]["name"] = "bad\nname";
    EXPECT_FALSE(decode_steam_catalog(control.dump()));

    auto wrong_type = document;
    wrong_type["games"][0]["installed"] = "true";
    EXPECT_FALSE(decode_steam_catalog(wrong_type.dump()));

    auto too_many = document;
    while (too_many["games"].size() <= platf::provider_scan::max_games) {
      auto entry = too_many["games"].front();
      entry["app_id"] = static_cast<std::uint32_t>(too_many["games"].size() + 7U);
      too_many["games"].push_back(std::move(entry));
    }
    EXPECT_FALSE(decode_steam_catalog(too_many.dump()));
  }
}  // namespace

TEST(ProviderScanArtwork, RevisionsAreBoundedPathFreeAndBackwardCompatible) {
  platf::steam::game_t game;
  game.app_id = 42;
  const auto encoded = platf::provider_scan::encode_steam_catalog({true, {game}});
  ASSERT_TRUE(encoded);
  auto doc = nlohmann::json::parse(*encoded);
  doc["games"][0]["artwork_revision"] = "123456";
  const auto decoded = platf::provider_scan::decode_steam_catalog(doc.dump());
  ASSERT_TRUE(decoded);
  EXPECT_EQ(decoded->games[0].session_artwork_revision, "123456");
  EXPECT_TRUE(decoded->games[0].artwork_path.empty());
  for (const auto &value : {"/home/user/cover.png", "123\n", "123456789012345678901"}) {
    doc["games"][0]["artwork_revision"] = value;
    EXPECT_FALSE(platf::provider_scan::decode_steam_catalog(doc.dump()));
  }
  doc["games"][0].erase("artwork_revision");
  EXPECT_TRUE(platf::provider_scan::decode_steam_catalog(doc.dump()));
  doc["games"][0] = nullptr;
  EXPECT_FALSE(platf::provider_scan::decode_steam_catalog(doc.dump()));
}
