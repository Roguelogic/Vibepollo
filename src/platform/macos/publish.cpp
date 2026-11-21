/**
 * @file src/platform/macos/publish.cpp
 * @brief Definitions for publishing services on macOS.
 */
// standard includes
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

// platform includes
#include <arpa/inet.h>
#include <dns_sd.h>
#include <ifaddrs.h>
#include <net/if.h>

// local includes
#include "src/config.h"
#include "src/logging.h"
#include "src/network.h"
#include "src/nvhttp.h"
#include "src/platform/common.h"

using namespace std::literals;

namespace platf::publish {
  namespace {
    /** @brief Custom deleter intended to be used for `std::unique_ptr<DNSServiceRef>`. */
    struct ServiceRefDeleter {
      typedef DNSServiceRef pointer;  ///< Type of object to be deleted.

      void operator()(pointer serviceRef) {
        DNSServiceRefDeallocate(serviceRef);
        BOOST_LOG(info) << "Deregistered DNS service."sv;
      }
    };

    std::vector<uint32_t> resolve_publish_interface_indices();
    void registrationCallback(DNSServiceRef, DNSServiceFlags, DNSServiceErrorType, const char *, const char *, const char *, void *);

    std::vector<DNSServiceRef> register_for_indices(const std::vector<uint32_t> &indices) {
      std::vector<DNSServiceRef> refs;
      refs.reserve(indices.size());
      for (const uint32_t iface_idx : indices) {
        DNSServiceRef serviceRef {};
        const auto status = DNSServiceRegister(
          &serviceRef,
          0,
          iface_idx,
          nullptr,
          platf::SERVICE_TYPE.data(),
          nullptr,
          nullptr,
          htons(net::map_port(nvhttp::PORT_HTTP)),
          0,
          nullptr,
          registrationCallback,
          nullptr
        );
        if (status != kDNSServiceErr_NoError) {
          BOOST_LOG(error) << "Failed immediately to register DNS service on if="sv << iface_idx << ": Error "sv << status;
          continue;
        }
        refs.push_back(serviceRef);
      }
      return refs;
    }

    /** @brief This class encapsulates the polling and deinitialization of our connection with
     *         the mDNS service, and refreshes registrations if interfaces (DHCP / VPN tunnels)
     *         come up after cold boot.
     */
    class deinit_t: public ::platf::deinit_t {
    public:
      deinit_t(std::vector<uint32_t> indices, std::vector<DNSServiceRef> serviceRefs):
          _indices(std::move(indices)),
          _refs(std::move(serviceRefs)) {
        _thread = std::thread {[this]() {
          platf::set_thread_name("publish::mdns");
          std::vector<bool> done(_refs.size(), false);
          auto next_if_check = std::chrono::steady_clock::now() + 5s;

          for (;;) {
            {
              std::unique_lock lock {_mutex};
              if (_stopRequested) {
                break;
              }
            }

            bool any_pending = false;
            auto fdset = fd_set {};
            FD_ZERO(&fdset);
            int max_fd = -1;
            for (std::size_t i = 0; i < _refs.size(); ++i) {
              if (done[i] || !_refs[i]) {
                continue;
              }
              const int sock = DNSServiceRefSockFD(_refs[i]);
              if (sock >= 0) {
                FD_SET(sock, &fdset);
                max_fd = std::max(max_fd, sock);
                any_pending = true;
              }
            }

            if (any_pending) {
              auto timeout = timeval {.tv_sec = 1, .tv_usec = 0};
              const auto ready = select(max_fd + 1, &fdset, nullptr, nullptr, &timeout);
              if (ready > 0) {
                for (std::size_t i = 0; i < _refs.size(); ++i) {
                  if (done[i] || !_refs[i]) {
                    continue;
                  }
                  const int sock = DNSServiceRefSockFD(_refs[i]);
                  if (sock >= 0 && FD_ISSET(sock, &fdset)) {
                    DNSServiceProcessResult(_refs[i]);
                    done[i] = true;
                  }
                }
              }
            } else {
              std::unique_lock lock {_mutex};
              if (_cv.wait_for(lock, 5s, [this] { return _stopRequested; })) {
                break;
              }
            }

            if (std::chrono::steady_clock::now() >= next_if_check) {
              next_if_check = std::chrono::steady_clock::now() + 5s;
              auto latest = resolve_publish_interface_indices();
              if (latest != _indices) {
                auto new_refs = register_for_indices(latest);
                if (!new_refs.empty()) {
                  for (auto ref : _refs) {
                    if (ref) {
                      DNSServiceRefDeallocate(ref);
                    }
                  }
                  _indices = std::move(latest);
                  _refs = std::move(new_refs);
                  done.assign(_refs.size(), false);
                }
              }
            }
          }
        }};
      }

      ~deinit_t() override {
        {
          std::lock_guard lock {_mutex};
          _stopRequested = true;
        }
        _cv.notify_all();
        if (_thread.joinable()) {
          _thread.join();
        }
        for (auto ref : _refs) {
          if (ref) {
            DNSServiceRefDeallocate(ref);
          }
        }
        if (!_refs.empty()) {
          BOOST_LOG(info) << "Deregistered DNS service."sv;
        }
      }

      deinit_t(const deinit_t &) = delete;
      deinit_t &operator=(const deinit_t &) = delete;

    private:
      std::mutex _mutex;
      std::condition_variable _cv;
      std::vector<uint32_t> _indices;
      std::vector<DNSServiceRef> _refs;
      std::thread _thread;
      bool _stopRequested = false;
    };

    /** @brief Callback that will be invoked when the mDNS service finishes registering our service.
     *  @param errorCode Describes whether the registration was successful.
     */
    void registrationCallback(DNSServiceRef /*serviceRef*/, DNSServiceFlags /*flags*/, DNSServiceErrorType errorCode, const char * /*name*/, const char * /*regtype*/, const char * /*domain*/, void * /*context*/) {
      if (errorCode != kDNSServiceErr_NoError) {
        BOOST_LOG(error) << "Failed to register DNS service: Error "sv << errorCode;
        return;
      }
      BOOST_LOG(info) << "Successfully registered DNS service."sv;
    }

    // Resolves which interface indices should advertise _nvstream._tcp:
    // - If `bind_address` is explicitly set, advertise only on that interface.
    // - Otherwise, if wired `en0` and Wi-Fi `en1` are both active on the exact same IPv4 subnet,
    //   advertise on every active IPv4 broadcast multicast interface (`en0`, ZeroTier `feth*`, etc.)
    //   EXCEPT redundant `en1` so LAN clients stay on wired 1GbE while avoiding IPv6-only
    //   point-to-point `utun*` tunnels.
    std::vector<uint32_t> resolve_publish_interface_indices() {
      ifaddrs *ifaddr = nullptr;
      if (getifaddrs(&ifaddr) != 0 || !ifaddr) {
        return {0};
      }

      const auto &bind_addr = config::sunshine.bind_address;
      if (!bind_addr.empty()) {
        uint32_t bound_idx = 0;
        char addr_buf[INET6_ADDRSTRLEN] {};
        for (auto *ifa = ifaddr; ifa != nullptr; ifa = ifa->ifa_next) {
          if (!ifa->ifa_addr || !(ifa->ifa_flags & IFF_UP)) {
            continue;
          }
          const void *src = nullptr;
          if (ifa->ifa_addr->sa_family == AF_INET) {
            src = &reinterpret_cast<const sockaddr_in *>(ifa->ifa_addr)->sin_addr;
          } else if (ifa->ifa_addr->sa_family == AF_INET6) {
            src = &reinterpret_cast<const sockaddr_in6 *>(ifa->ifa_addr)->sin6_addr;
          }
          if (src && inet_ntop(ifa->ifa_addr->sa_family, src, addr_buf, sizeof(addr_buf)) && bind_addr == addr_buf) {
            bound_idx = if_nametoindex(ifa->ifa_name);
            break;
          }
        }
        freeifaddrs(ifaddr);
        return {bound_idx};
      }

      bool has_en0_v4 = false;
      uint32_t en0_net = 0;
      bool en1_same_subnet = false;
      std::set<uint32_t> active_multicast_indices;
      uint32_t en1_idx = 0;

      for (auto *ifa = ifaddr; ifa != nullptr; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || !ifa->ifa_name) {
          continue;
        }
        if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK) ||
            (ifa->ifa_flags & IFF_POINTOPOINT) || !(ifa->ifa_flags & IFF_BROADCAST) ||
            !(ifa->ifa_flags & IFF_MULTICAST)) {
          continue;
        }
        if (std::strncmp(ifa->ifa_name, "awdl", 4) == 0 ||
            std::strncmp(ifa->ifa_name, "llw", 3) == 0 ||
            std::strncmp(ifa->ifa_name, "anpi", 4) == 0 ||
            std::strncmp(ifa->ifa_name, "ap", 2) == 0 ||
            std::strncmp(ifa->ifa_name, "bridge", 6) == 0) {
          continue;
        }
        if (ifa->ifa_addr->sa_family != AF_INET) {
          continue;
        }
        const uint32_t idx = if_nametoindex(ifa->ifa_name);
        if (idx == 0) {
          continue;
        }
        active_multicast_indices.insert(idx);
        if (ifa->ifa_netmask) {
          const uint32_t addr = reinterpret_cast<const sockaddr_in *>(ifa->ifa_addr)->sin_addr.s_addr;
          const uint32_t mask = reinterpret_cast<const sockaddr_in *>(ifa->ifa_netmask)->sin_addr.s_addr;
          if (std::strcmp(ifa->ifa_name, "en0") == 0) {
            has_en0_v4 = true;
            en0_net = addr & mask;
          }
        }
      }

      if (has_en0_v4) {
        for (auto *ifa = ifaddr; ifa != nullptr; ifa = ifa->ifa_next) {
          if (!ifa->ifa_addr || !ifa->ifa_netmask || !ifa->ifa_name) {
            continue;
          }
          if ((ifa->ifa_flags & IFF_UP) && ifa->ifa_addr->sa_family == AF_INET && std::strcmp(ifa->ifa_name, "en1") == 0) {
            const uint32_t addr = reinterpret_cast<const sockaddr_in *>(ifa->ifa_addr)->sin_addr.s_addr;
            const uint32_t mask = reinterpret_cast<const sockaddr_in *>(ifa->ifa_netmask)->sin_addr.s_addr;
            if ((addr & mask) == en0_net) {
              en1_same_subnet = true;
              en1_idx = if_nametoindex("en1");
              break;
            }
          }
        }
      }
      freeifaddrs(ifaddr);

      if (en1_same_subnet && en1_idx != 0) {
        active_multicast_indices.erase(en1_idx);
        if (!active_multicast_indices.empty()) {
          return {active_multicast_indices.begin(), active_multicast_indices.end()};
        }
      }
      return {0};
    }
  }  // anonymous namespace

  [[nodiscard]] std::unique_ptr<::platf::deinit_t> start() {
    auto indices = resolve_publish_interface_indices();
    auto refs = register_for_indices(indices);
    if (refs.empty()) {
      return nullptr;
    }
    return std::make_unique<deinit_t>(std::move(indices), std::move(refs));
  }
}  // namespace platf::publish
