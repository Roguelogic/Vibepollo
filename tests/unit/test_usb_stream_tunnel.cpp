/**
 * @file tests/unit/test_usb_stream_tunnel.cpp
 * @brief Unit and mock-usbmuxd integration tests for VoidLink USB wired streaming tunnel.
 */
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <future>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <unistd.h>
#include <vector>

#include <boost/asio.hpp>
#include <boost/property_tree/ptree.hpp>
#include <boost/property_tree/xml_parser.hpp>
#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "src/usb_stream_tunnel.h"

namespace {
  namespace asio = boost::asio;
  namespace pt = boost::property_tree;
  using asio::ip::tcp;
  using asio::ip::udp;
  using mux_protocol = asio::local::stream_protocol;
  using namespace std::chrono_literals;

  std::uint32_t read_u32_le(const char *p) {
    std::uint32_t v = 0;
    for (unsigned i = 0; i < 4; ++i) {
      v |= std::uint32_t(static_cast<unsigned char>(p[i])) << (8 * i);
    }
    return v;
  }

  void write_u32_le(char *p, std::uint32_t v) {
    for (unsigned i = 0; i < 4; ++i) {
      p[i] = static_cast<char>(v >> (8 * i));
    }
  }

  const pt::ptree *plist_find(const pt::ptree &dict, std::string_view name) {
    for (auto it = dict.begin(); it != dict.end(); ++it) {
      if (it->first == "key" && it->second.data() == name) {
        ++it;
        return it == dict.end() ? nullptr : &it->second;
      }
    }
    return nullptr;
  }

  void send_usbmux_plist(mux_protocol::socket &sock, std::uint32_t tag, const std::string &xml_body) {
    std::array<char, 16> hdr {};
    write_u32_le(hdr.data() + 0, static_cast<std::uint32_t>(hdr.size() + xml_body.size()));
    write_u32_le(hdr.data() + 4, 1);
    write_u32_le(hdr.data() + 8, 8);
    write_u32_le(hdr.data() + 12, tag);
    asio::write(sock, asio::buffer(hdr));
    asio::write(sock, asio::buffer(xml_body));
  }

  nlohmann::json read_tunnel_header(mux_protocol::socket &sock) {
    std::array<unsigned char, 2> len_buf {};
    asio::read(sock, asio::buffer(len_buf));
    const std::size_t len = (std::size_t(len_buf[0]) << 8) | len_buf[1];
    std::string payload(len, '\0');
    asio::read(sock, asio::buffer(payload.data(), len));
    return nlohmann::json::parse(payload);
  }
}  // namespace

TEST(UsbStreamTunnelTest, AppendVideoDatagramFramingAndBounds) {
  std::vector<char> batch;
  EXPECT_FALSE(usb_stream_tunnel::append_video_datagram(batch, "", ""));

  const std::string prefix = "PREF";
  const std::string payload = "HELLO_VIDEO";
  ASSERT_TRUE(usb_stream_tunnel::append_video_datagram(batch, prefix, payload));
  const std::size_t expected_len = prefix.size() + payload.size();
  ASSERT_EQ(batch.size(), 2 + expected_len);
  EXPECT_EQ(static_cast<unsigned char>(batch[0]), (expected_len >> 8) & 0xFF);
  EXPECT_EQ(static_cast<unsigned char>(batch[1]), expected_len & 0xFF);
  EXPECT_EQ(std::string_view(batch.data() + 2, expected_len), "PREFHELLO_VIDEO");

  std::string oversized(65508, 'X');
  EXPECT_FALSE(usb_stream_tunnel::append_video_datagram(batch, "", oversized));
}

TEST(UsbStreamTunnelTest, VideoChannelLifecycleAndOverflow) {
  usb_stream_tunnel::video_channel ch;
  EXPECT_TRUE(ch.active());
  EXPECT_FALSE(ch.enqueue({}));

  std::vector<char> pkt {'a', 'b', 'c'};
  ASSERT_TRUE(ch.enqueue(pkt));

  std::vector<char> out;
  ASSERT_TRUE(ch.next_batch(out));
  EXPECT_EQ(out, pkt);

  ch.reader_started();
  EXPECT_TRUE(ch.wait_for_reader(50ms));

  // Exceeding 2 MiB bounded queue closes the channel cleanly.
  std::vector<char> huge(2 * 1024 * 1024 + 1, 'z');
  EXPECT_FALSE(ch.enqueue(std::move(huge)));
  EXPECT_FALSE(ch.active());
  EXPECT_FALSE(ch.wait_for_reader(10ms));
}

TEST(UsbStreamTunnelTest, EndToEndMockUsbmuxdOfferRelaysAndDirectVideo) {
  const std::string sock_path = "/tmp/vp_usbmux_" + std::to_string(::getpid()) + ".sock";
  ::unlink(sock_path.c_str());

  asio::io_context service_io;

  // Local TCP echo service (simulates GameStream HTTP/HTTPS/RTSP on port_http).
  tcp::acceptor tcp_acc {service_io, tcp::endpoint {asio::ip::address_v4::loopback(), 0}};
  const std::uint16_t tcp_port = tcp_acc.local_endpoint().port();

  // Local UDP echo service (simulates ENet control/audio on control port).
  udp::socket udp_srv {service_io, udp::endpoint {asio::ip::address_v4::loopback(), 0}};
  const std::uint16_t udp_port = udp_srv.local_endpoint().port();

  std::thread echo_services([&]() {
    std::thread tcp_echo([&]() {
      boost::system::error_code ec;
      tcp::socket peer {service_io};
      if (!tcp_acc.accept(peer, ec)) {
        std::array<char, 64> buf {};
        const auto n = peer.read_some(asio::buffer(buf), ec);
        if (!ec && n > 0) {
          asio::write(peer, asio::buffer(buf.data(), n), ec);
        }
        peer.shutdown(tcp::socket::shutdown_both, ec);
      }
    });
    std::thread udp_echo([&]() {
      boost::system::error_code ec;
      std::array<char, 256> buf {};
      udp::endpoint sender;
      const auto n = udp_srv.receive_from(asio::buffer(buf), sender, 0, ec);
      if (!ec && n > 0) {
        udp_srv.send_to(asio::buffer(buf.data(), n), sender, 0, ec);
      }
    });
    tcp_echo.join();
    udp_echo.join();
  });

  asio::io_context mux_io;
  mux_protocol::acceptor mux_acc {mux_io, mux_protocol::endpoint {sock_path}};

  std::promise<mux_protocol::socket> offer_Promise;
  std::promise<mux_protocol::socket> tcp_chan_Promise;
  std::promise<mux_protocol::socket> udp_chan_Promise;
  std::promise<std::pair<mux_protocol::socket, nlohmann::json>> video_chan_Promise;

  std::atomic<bool> mux_stop {false};
  std::thread mock_usbmuxd([&]() {
    while (!mux_stop.load()) {
      mux_protocol::socket client {mux_io};
      boost::system::error_code ec;
      mux_acc.accept(client, ec);
      if (ec) {
        break;
      }
      std::thread([&, sock = std::move(client)]() mutable {
        boost::system::error_code io_ec;
        std::array<char, 16> hdr {};
        if (asio::read(sock, asio::buffer(hdr), io_ec) != 16 || io_ec) {
          return;
        }
        const auto total_len = read_u32_le(hdr.data());
        const auto tag = read_u32_le(hdr.data() + 12);
        std::string xml(total_len - 16, '\0');
        if (asio::read(sock, asio::buffer(xml.data(), xml.size()), io_ec) != xml.size() || io_ec) {
          return;
        }
        std::istringstream iss {xml};
        pt::ptree req;
        pt::read_xml(iss, req, pt::xml_parser::trim_whitespace);
        const auto &dict = req.get_child("plist.dict");
        const auto *msg_type = plist_find(dict, "MessageType");
        if (!msg_type) {
          return;
        }
        if (msg_type->data() == "ListDevices") {
          const std::string reply =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            "<plist version=\"1.0\"><dict><key>DeviceList</key><array>"
            "<dict><key>DeviceID</key><integer>8</integer><key>Properties</key>"
            "<dict><key>ConnectionType</key><string>Network</string></dict></dict>"
            "<dict><key>DeviceID</key><integer>7</integer><key>Properties</key>"
            "<dict><key>ConnectionType</key><string>USB</string></dict></dict>"
            "</array></dict></plist>";
          send_usbmux_plist(sock, tag, reply);
        } else if (msg_type->data() == "Connect") {
          const auto *dev_id = plist_find(dict, "DeviceID");
          const auto *port_num = plist_find(dict, "PortNumber");
          constexpr unsigned expected_be_port = ((41849U & 255U) << 8) | (41849U >> 8);
          if (!dev_id || dev_id->get_value<unsigned>(0) != 7 ||
              !port_num || port_num->get_value<unsigned>(0) != expected_be_port) {
            send_usbmux_plist(sock, tag, "<plist version=\"1.0\"><dict><key>Number</key><integer>3</integer></dict></plist>");
            return;
          }
          send_usbmux_plist(sock, tag, "<plist version=\"1.0\"><dict><key>Number</key><integer>0</integer></dict></plist>");
          const auto tunnel_hdr = read_tunnel_header(sock);
          const auto type = tunnel_hdr.at("type").get<std::string>();
          if (type == "offer") {
            offer_Promise.set_value(std::move(sock));
          } else if (type == "channel") {
            const auto id = tunnel_hdr.at("id").get<std::uint32_t>();
            if (id == 1) {
              tcp_chan_Promise.set_value(std::move(sock));
            } else if (id == 2) {
              udp_chan_Promise.set_value(std::move(sock));
            }
          } else if (type == "video") {
            video_chan_Promise.set_value({std::move(sock), tunnel_hdr});
          }
        }
      }).detach();
    }
  });

  std::atomic<unsigned> uuid_seq {0};
  auto make_uuid = [&]() {
    const unsigned n = ++uuid_seq;
    char buf[37] {};
    std::snprintf(buf, sizeof(buf), "11111111-2222-4333-8444-%012u", n);
    return std::string(buf);
  };

  const usb_stream_tunnel::ports_t ports {
    tcp_port,
    static_cast<std::uint16_t>(tcp_port + 1),
    static_cast<std::uint16_t>(tcp_port + 2),
    static_cast<std::uint16_t>(udp_port + 1),
    udp_port,
    static_cast<std::uint16_t>(udp_port + 2),
    static_cast<std::uint16_t>(udp_port + 3),
  };

  util::jthread tunnel_worker(
    usb_stream_tunnel::run,
    std::string("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
    std::string("MacStudio"),
    std::string("127.0.0.1"),
    ports,
    make_uuid,
    sock_path
  );

  auto offer_fut = offer_Promise.get_future();
  ASSERT_EQ(offer_fut.wait_for(3s), std::future_status::ready);
  auto control_sock = offer_fut.get();

  // 1. Open TCP channel (service 0 -> tcp_port) and verify echo.
  const std::string open_tcp = "OPEN 1 0\n";
  asio::write(control_sock, asio::buffer(open_tcp));
  auto tcp_fut = tcp_chan_Promise.get_future();
  ASSERT_EQ(tcp_fut.wait_for(3s), std::future_status::ready);
  auto tcp_chan = tcp_fut.get();
  const std::string ping_http = "GET /serverinfo";
  asio::write(tcp_chan, asio::buffer(ping_http));
  std::string tcp_reply(ping_http.size(), '\0');
  asio::read(tcp_chan, asio::buffer(tcp_reply.data(), tcp_reply.size()));
  EXPECT_EQ(tcp_reply, ping_http);
  tcp_chan.close();

  // 2. Open UDP channel (service 4 -> udp_port) and verify length-prefixed datagram relay.
  const std::string open_udp = "OPEN 2 4\n";
  asio::write(control_sock, asio::buffer(open_udp));
  auto udp_fut = udp_chan_Promise.get_future();
  ASSERT_EQ(udp_fut.wait_for(3s), std::future_status::ready);
  auto udp_chan = udp_fut.get();
  const std::string dgram = "ENET_PING";
  std::vector<char> framed_udp {
    static_cast<char>((dgram.size() >> 8) & 0xFF),
    static_cast<char>(dgram.size() & 0xFF),
  };
  framed_udp.insert(framed_udp.end(), dgram.begin(), dgram.end());
  asio::write(udp_chan, asio::buffer(framed_udp));
  std::vector<char> udp_echo_buf(framed_udp.size());
  asio::read(udp_chan, asio::buffer(udp_echo_buf));
  EXPECT_EQ(udp_echo_buf, framed_udp);
  udp_chan.close();

  // 3. Open Direct USB Video channel (service 7), claim single-use token, send 'V', receive video batch.
  const std::string open_vid = "OPEN 3 7\n";
  asio::write(control_sock, asio::buffer(open_vid));
  auto vid_fut = video_chan_Promise.get_future();
  ASSERT_EQ(vid_fut.wait_for(3s), std::future_status::ready);
  auto [vid_sock, vid_hdr] = vid_fut.get();
  const auto token = vid_hdr.at("token").get<std::string>();
  EXPECT_EQ(token.size(), 36U);

  auto claimed = usb_stream_tunnel::claim_video(token);
  ASSERT_NE(claimed, nullptr);
  // Single-use token cannot be claimed twice.
  EXPECT_EQ(usb_stream_tunnel::claim_video(token), nullptr);

  const char start_v = 'V';
  asio::write(vid_sock, asio::buffer(&start_v, 1));
  ASSERT_TRUE(claimed->wait_for_reader(2s));

  std::vector<char> video_batch;
  ASSERT_TRUE(usb_stream_tunnel::append_video_datagram(video_batch, "ENC_", "IDR_SLICE_DATA"));
  const auto expected_video_batch = video_batch;
  ASSERT_TRUE(claimed->enqueue(std::move(video_batch)));

  std::vector<char> received_video(expected_video_batch.size());
  asio::read(vid_sock, asio::buffer(received_video));
  EXPECT_EQ(received_video, expected_video_batch);

  claimed->close();
  vid_sock.close();
  control_sock.close();

  tunnel_worker.request_stop();
  tunnel_worker.join();

  mux_stop.store(true);
  boost::system::error_code close_ec;
  mux_acc.close(close_ec);
  mock_usbmuxd.join();
  echo_services.join();
  ::unlink(sock_path.c_str());
}
