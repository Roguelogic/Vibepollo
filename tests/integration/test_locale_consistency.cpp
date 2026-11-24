/**
 * @file tests/integration/test_locale_consistency.cpp
 * @brief Verify backend locale allowlist covers native macOS UI locales and lightweight web assets exist.
 */
#include "../tests_common.h"

#include <filesystem>
#include <regex>
#include <set>
#include <string>
#include <vector>

#include "src/file_handler.h"

namespace {

namespace fs = std::filesystem;
using locale_set = std::set<std::string, std::less<>>;

locale_set extract_config_cpp_locales() {
  locale_set locales;
  const std::string content = file_handler::read_file("src/config.cpp");
  const std::regex locale_section(R"(string_restricted_f\s*\(\s*vars\s*,\s*"locale"[^}]*\{([^}]*)\})");
  std::smatch match;

  if (!std::regex_search(content, match, locale_section)) {
    return locales;
  }

  const std::regex locale_pattern(R"delimiter("([^"]+)"sv)delimiter");
  for (std::sregex_iterator iter(match[1].first, match[1].second, locale_pattern), end; iter != end; ++iter) {
    locales.insert((*iter)[1].str());
  }

  return locales;
}

}  // namespace

TEST(LocaleConsistency, BackendLocalesCoverNativeMacOSLocales) {
  const auto config_locales = extract_config_cpp_locales();

  ASSERT_FALSE(config_locales.empty());
  EXPECT_TRUE(config_locales.contains("en"));
  EXPECT_TRUE(config_locales.contains("ko"));
}

TEST(LocaleConsistency, LightweightWebConsoleAndTrayIconsExist) {
  const std::vector<fs::path> required_files {
    "src_assets/common/assets/web/index.html",
    "src_assets/common/assets/web/assets/app.js",
    "src_assets/common/assets/web/assets/style.css",
    "src_assets/common/assets/web/images/logo-apollo.svg",
    "src_assets/common/assets/web/images/apollo-playing.svg",
    "src_assets/common/assets/web/images/apollo-pausing.svg",
    "src_assets/common/assets/web/images/apollo-locked.svg",
    "src_assets/common/assets/web/images/logo-apollo-45.png",
    "src_assets/common/assets/web/images/apollo.ico",
  };
  for (const auto &path : required_files) {
    EXPECT_TRUE(fs::is_regular_file(path)) << "Missing required asset: " << path;
  }
}
