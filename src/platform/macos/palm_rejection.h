/**
 * @file src/platform/macos/palm_rejection.h
 * @brief Host-side Apple Pencil palm rejection and balanced client-trackpad gesture state machine.
 */
#pragma once

#include <chrono>
#include <cmath>
#include <cstdint>
#include <vector>

namespace platf::macos_input_policy {

  inline constexpr std::uint32_t voidlink_pencil_touch_id = 666666u;

  /**
   * @brief Determines whether an incoming `LI_TOUCH_EVENT_HOVER` during an active Pencil scroll/tap
   *        contact indicates the stylus tip has lifted off the glass (e.g. VoidLink `Stroke Type: HD`
   *        transitioning from `MOVE` directly to `HOVER` without emitting `UP`).
   */
  constexpr bool should_finish_pen_contact_on_hover(
    const float hover_distance,
    const int consecutive_hover_packets,
    const std::chrono::milliseconds since_last_contact
  ) noexcept {
    if (hover_distance > 0.002f) {
      return consecutive_hover_packets >= 2 || since_last_contact >= std::chrono::milliseconds(16);
    }
    return consecutive_hover_packets >= 3 || since_last_contact >= std::chrono::milliseconds(32);
  }

  /**
   * @brief Suppresses stray finger/palm contacts while Apple Pencil is hovering or drawing,
   *        with bounded silence timeouts so dropped UDP `HOVER_LEAVE` packets never block input.
   */
  class palm_rejection_tracker_t {
  public:
    using clock_t = std::chrono::steady_clock;
    using time_point_t = clock_t::time_point;

    static constexpr auto post_pen_cooldown = std::chrono::milliseconds(180);
    static constexpr auto post_leave_cooldown = std::chrono::milliseconds(80);
    static constexpr auto hover_silence_timeout = std::chrono::milliseconds(350);
    static constexpr auto tip_silence_timeout = std::chrono::milliseconds(2000);

    void reset() noexcept {
      active_ = false;
      tip_down_ = false;
      has_event_time_ = false;
      has_leave_time_ = false;
    }

    void note_pen_activity(const time_point_t now, const bool tip_down) noexcept {
      active_ = true;
      tip_down_ = tip_down;
      last_event_time_ = now;
      has_event_time_ = true;
    }

    void note_pen_leave(const time_point_t now) noexcept {
      active_ = false;
      tip_down_ = false;
      has_event_time_ = false;
      last_leave_time_ = now;
      has_leave_time_ = true;
    }

    bool should_reject_touch(
      const bool enabled,
      const std::uint32_t pointer_id,
      const time_point_t now
    ) noexcept {
      if (!enabled || pointer_id == voidlink_pencil_touch_id) {
        return false;
      }

      if (active_ && has_event_time_) {
        const auto timeout = tip_down_ ? tip_silence_timeout : hover_silence_timeout;
        if (now - last_event_time_ <= timeout) {
          return true;
        }
        active_ = false;
        tip_down_ = false;
      }

      if (has_event_time_ && (now - last_event_time_) <= post_pen_cooldown) {
        return true;
      }
      if (has_leave_time_ && (now - last_leave_time_) <= post_leave_cooldown) {
        return true;
      }
      return false;
    }

  private:
    bool active_ {};
    bool tip_down_ {};
    bool has_event_time_ {};
    bool has_leave_time_ {};
    time_point_t last_event_time_ {};
    time_point_t last_leave_time_ {};
  };

  struct trackpad_gesture_packet_t {
    std::int64_t subtype {};
    std::int64_t phase {};
    double amount {};
  };

  enum class cg_gesture_value_slot_e : std::uint8_t {
    magnify_113,
    rotate_114,
  };

  struct cg_gesture_field_write_t {
    cg_gesture_value_slot_e slot {cg_gesture_value_slot_e::magnify_113};
    double value {};
  };

  /**
   * @brief Balances client-recognized trackpad pinch/rotate packets (`SS_MAC_MAGNIFY_MAGIC` /
   *        `SS_MAC_ROTATE_MAGIC`) without bookend subtypes (`60/61/62`) or union slot overwrites.
   */
  class trackpad_gesture_emitter_t {
  public:
    static constexpr std::int64_t subtype_rotate = 5;
    static constexpr std::int64_t subtype_magnify = 8;

    static constexpr std::int64_t phase_began = 1;
    static constexpr std::int64_t phase_changed = 2;
    static constexpr std::int64_t phase_ended = 4;
    static constexpr std::int64_t phase_cancelled = 8;

    static constexpr bool is_allowed_packet(const trackpad_gesture_packet_t &pkt) noexcept {
      if (pkt.subtype != subtype_magnify && pkt.subtype != subtype_rotate) {
        return false;
      }
      return pkt.phase == phase_began ||
             pkt.phase == phase_changed ||
             pkt.phase == phase_ended ||
             pkt.phase == phase_cancelled;
    }

    // SkyLight's `SLGestureEventData` aliases CGEventFields 113 (`Magnify`) and 114 (`Rotate`)
    // to the same 32-bit float union slot; callers must write only the active subtype's slot.
    static constexpr cg_gesture_field_write_t resolve_value_field_write(
      const trackpad_gesture_packet_t &pkt
    ) noexcept {
      if (pkt.subtype == subtype_rotate) {
        return {cg_gesture_value_slot_e::rotate_114, pkt.amount};
      }
      return {cg_gesture_value_slot_e::magnify_113, pkt.amount};
    }

    std::vector<trackpad_gesture_packet_t> begin(const std::int64_t subtype) {
      bool *slot = active_slot(subtype);
      if (!slot || *slot) {
        return {};
      }
      *slot = true;
      return {{subtype, phase_began, 0.0}};
    }

    std::vector<trackpad_gesture_packet_t> change(const std::int64_t subtype, const double amount) {
      bool *slot = active_slot(subtype);
      if (!slot || !std::isfinite(amount)) {
        return {};
      }
      std::vector<trackpad_gesture_packet_t> out;
      if (!*slot) {
        *slot = true;
        out.push_back({subtype, phase_began, 0.0});
      }
      out.push_back({subtype, phase_changed, amount});
      return out;
    }

    std::vector<trackpad_gesture_packet_t> end(const std::int64_t subtype, const bool cancelled = false) {
      bool *slot = active_slot(subtype);
      if (!slot || !*slot) {
        return {};
      }
      *slot = false;
      return {{subtype, cancelled ? phase_cancelled : phase_ended, 0.0}};
    }

    std::vector<trackpad_gesture_packet_t> cancel_all() {
      std::vector<trackpad_gesture_packet_t> out;
      if (magnify_active_) {
        magnify_active_ = false;
        out.push_back({subtype_magnify, phase_cancelled, 0.0});
      }
      if (rotate_active_) {
        rotate_active_ = false;
        out.push_back({subtype_rotate, phase_cancelled, 0.0});
      }
      return out;
    }

  private:
    bool *active_slot(const std::int64_t subtype) noexcept {
      if (subtype == subtype_magnify) {
        return &magnify_active_;
      }
      if (subtype == subtype_rotate) {
        return &rotate_active_;
      }
      return nullptr;
    }

    bool magnify_active_ {};
    bool rotate_active_ {};
  };

}  // namespace platf::macos_input_policy
