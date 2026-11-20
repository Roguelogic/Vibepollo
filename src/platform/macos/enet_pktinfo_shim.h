/**
 * @file src/platform/macos/enet_pktinfo_shim.h
 * @brief Pins ENet IPv4 IP_PKTINFO replies on macOS to their actual source interface (preferring wired en0).
 *
 * Injected into third-party/moonlight-common-c/enet/unix.c via CMake -include so the nested
 * enet submodule remains completely unmodified for clean recursive clones and CI builds.
 */
#pragma once

#if defined(__APPLE__)
#ifndef __APPLE_USE_RFC_3542
#define __APPLE_USE_RFC_3542 1
#endif

#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>

static inline unsigned int
enet_macos_resolve_ifindex_v4(in_addr_t src_addr) {
  static _Atomic uint32_t cached_addr = 0;
  static _Atomic unsigned int cached_idx = 0;
  if (src_addr == 0) {
    return 0;
  }
  if (atomic_load_explicit(&cached_addr, memory_order_relaxed) == src_addr) {
    unsigned int idx = atomic_load_explicit(&cached_idx, memory_order_relaxed);
    if (idx != 0) {
      return idx;
    }
  }
  struct ifaddrs *ifaddr = NULL;
  unsigned int found = 0;
  if (getifaddrs(&ifaddr) == 0 && ifaddr != NULL) {
    for (int pass = 0; pass < 2 && found == 0; ++pass) {
      for (struct ifaddrs *ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == NULL || ifa->ifa_name == NULL ||
            !(ifa->ifa_flags & IFF_UP) || ifa->ifa_addr->sa_family != AF_INET) {
          continue;
        }
        int is_en0 = (strcmp(ifa->ifa_name, "en0") == 0);
        if ((pass == 0) != is_en0) {
          continue;
        }
        if (((const struct sockaddr_in *) ifa->ifa_addr)->sin_addr.s_addr == src_addr) {
          found = if_nametoindex(ifa->ifa_name);
          if (found != 0) {
            break;
          }
        }
      }
    }
    freeifaddrs(ifaddr);
  }
  if (found != 0) {
    atomic_store_explicit(&cached_addr, src_addr, memory_order_relaxed);
    atomic_store_explicit(&cached_idx, found, memory_order_relaxed);
  }
  return found;
}

static inline ssize_t
enet_macos_sendmsg(int socket_fd, struct msghdr *msg_hdr, int flags) {
#ifdef IP_PKTINFO
  if (msg_hdr != NULL && msg_hdr->msg_control != NULL &&
      msg_hdr->msg_controllen >= CMSG_SPACE(sizeof(struct in_pktinfo))) {
    struct cmsghdr *chdr = CMSG_FIRSTHDR(msg_hdr);
    if (chdr != NULL && chdr->cmsg_level == IPPROTO_IP && chdr->cmsg_type == IP_PKTINFO) {
      struct in_pktinfo pkt_info;
      memcpy(&pkt_info, CMSG_DATA(chdr), sizeof(pkt_info));
      if (pkt_info.ipi_ifindex == 0 && pkt_info.ipi_spec_dst.s_addr != 0) {
        pkt_info.ipi_ifindex = enet_macos_resolve_ifindex_v4(pkt_info.ipi_spec_dst.s_addr);
        memcpy(CMSG_DATA(chdr), &pkt_info, sizeof(pkt_info));
      }
    }
  }
#endif
  return (sendmsg)(socket_fd, msg_hdr, flags);
}

#define sendmsg(s, m, f) enet_macos_sendmsg((s), (m), (f))
#endif
