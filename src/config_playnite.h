/**
 * @file src/config_playnite.h
 * @brief Shared ID/name pair type used by app sync metadata.
 */
#pragma once

#include <string>

namespace config {

  struct id_name_t {
    std::string id;
    std::string name;
  };

}  // namespace config
