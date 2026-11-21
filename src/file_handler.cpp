/**
 * @file src/file_handler.cpp
 * @brief Default operating-system adapter for file handling policy.
 */
#include "file_handler.h"

#include "logging.h"

#include <cerrno>
#include <chrono>
#include <fcntl.h>
#include <fstream>
#include <functional>
#include <sys/stat.h>
#include <system_error>
#include <thread>
#include <unistd.h>

namespace file_handler {
  namespace {
    class native_filesystem_t: public filesystem_t {
    public:
      bool exists(const std::filesystem::path &path) const override {
        std::error_code error;
        return std::filesystem::exists(path, error);
      }

      bool create_directories(const std::filesystem::path &path) override {
        std::error_code error;
        const bool created = std::filesystem::create_directories(path, error);
        return !error && (created || std::filesystem::exists(path));
      }

      std::string read(const std::filesystem::path &path) const override {
        std::ifstream input(path);
        return std::string {(std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>()};
      }

      bool write(const std::filesystem::path &path, std::string_view contents) override {
        // Atomic callers always write a fresh temporary path. O_EXCL and
        // O_NOFOLLOW prevent a same-directory attacker from redirecting a
        // predictable temporary name through a pre-positioned symlink.
        const int fd = ::open(
          path.c_str(),
          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
          S_IRUSR | S_IWUSR
        );
        if (fd < 0) {
          return false;
        }

        size_t offset = 0;
        bool success = true;
        while (offset < contents.size()) {
          const auto written = ::write(fd, contents.data() + offset, contents.size() - offset);
          if (written < 0) {
            if (errno == EINTR) {
              continue;
            }
            success = false;
            break;
          }
          if (written == 0) {
            success = false;
            break;
          }
          offset += static_cast<size_t>(written);
        }

        if (success && ::fsync(fd) != 0) {
          success = false;
        }
        if (::close(fd) != 0) {
          success = false;
        }
        return success;
      }

      replace_result_e replace(const std::filesystem::path &temporary,
                               const std::filesystem::path &target) override {
        std::error_code error;
        std::filesystem::rename(temporary, target, error);
        if (!error) {
          return replace_result_e::success;
        }
        return error == std::errc::permission_denied ? replace_result_e::access_denied : replace_result_e::error;
      }

      std::optional<bool> read_only(const std::filesystem::path &path) const override {
        (void) path;
        return false;
      }

      bool set_read_only(const std::filesystem::path &path, bool value) override {
        (void) path;
        (void) value;
        return false;
      }

      void remove(const std::filesystem::path &path) override {
        std::error_code error;
        std::filesystem::remove(path, error);
      }

      std::filesystem::path temporary_path(const std::filesystem::path &target) override {
        const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
        const auto tid = std::hash<std::thread::id> {}(std::this_thread::get_id());
        auto temporary = target;
        temporary += ".tmp." + std::to_string(stamp) + "." + std::to_string(tid);
        return temporary;
      }
    };

    handler_t &default_handler() {
      static native_filesystem_t filesystem;
      static handler_t handler {filesystem, [](std::string_view message) {
        BOOST_LOG(error) << message;
      }};
      return handler;
    }
  }  // namespace

  std::string get_parent_directory(const std::string &path) {
    return default_handler().get_parent_directory(path);
  }

  bool make_directory(const std::string &path) {
    return default_handler().make_directory(path);
  }

  std::string read_file(const char *path) {
    return default_handler().read_file(path);
  }

  int write_file(const char *path, const std::string_view &contents) {
    return default_handler().write_file(path, contents);
  }
}  // namespace file_handler
