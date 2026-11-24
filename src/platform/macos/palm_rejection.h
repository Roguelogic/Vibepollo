/**
 * @file src/platform/macos/palm_rejection.h
 * @brief Host-side Apple Pencil palm rejection and balanced client-trackpad gesture state machine.
 */
#pragma once

#include <algorithm>
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

  /**
   * @brief Sanitizes Apple Pencil / stylus contact pressure against client-side altitude
   *        divide-by-zero blowups (`+Inf`/`NaN`/`>1.5`), single-sample jumps to `1.0` (e.g.
   *        when a client LUT clamps `+Inf` to `1.0`), and spurious `0.0 -> 0.5` jumps on light
   *        touch onset/taper or side-button packets.
   */
  class pen_pressure_sanitizer_t {
  public:
    static constexpr double legacy_default_pressure = 0.5;
    static constexpr double light_contact_floor = 0.005;
    static constexpr double max_spike_threshold = 0.98;
    static constexpr double confirm_high_threshold = 0.85;
    static constexpr double sudden_jump_delta = 0.35;
    static constexpr double high_baseline_threshold = 0.65;
    static constexpr std::uint8_t tilt_unknown = 0xFF;

    void reset() noexcept {
      in_stroke_ = false;
      has_seen_real_pressure_ = false;
      has_seen_variable_pressure_ = false;
      has_seen_normal_tilt_ = false;
      pending_max_spike_ = false;
      last_emitted_pressure_ = 0.0;
    }

    void end_stroke() noexcept {
      in_stroke_ = false;
      pending_max_spike_ = false;
      last_emitted_pressure_ = 0.0;
    }

    double last_pressure() const noexcept {
      return in_stroke_ ? last_emitted_pressure_ : 0.0;
    }

    double resolve(
      const bool tip_pressed,
      const float clamped_pressure,
      const bool pressure_invalid,
      const bool is_button_only,
      const std::uint8_t tilt_deg
    ) noexcept {
      if (!tip_pressed) {
        end_stroke();
        return 0.0;
      }

      if (tilt_deg != tilt_unknown && tilt_deg <= 78) {
        has_seen_normal_tilt_ = true;
      }

      if (is_button_only) {
        if (in_stroke_) {
          return last_emitted_pressure_;
        }
        return has_seen_real_pressure_ ? light_contact_floor : legacy_default_pressure;
      }

      const bool bad_altitude_spike =
        has_seen_normal_tilt_ &&
        tilt_deg != tilt_unknown &&
        tilt_deg >= 88 &&
        clamped_pressure >= 0.95f &&
        (!in_stroke_ || last_emitted_pressure_ < high_baseline_threshold);

      if (pressure_invalid || bad_altitude_spike) {
        pending_max_spike_ = false;
        if (in_stroke_) {
          return last_emitted_pressure_;
        }
        const double fallback = has_seen_variable_pressure_ ? light_contact_floor : legacy_default_pressure;
        in_stroke_ = true;
        last_emitted_pressure_ = fallback;
        return fallback;
      }

      const double p = std::isfinite(clamped_pressure) ? std::clamp<double>(clamped_pressure, 0.0, 1.0) : 0.0;
      if (p > 0.0) {
        has_seen_real_pressure_ = true;
        if (p > 0.01 && p < 0.95) {
          has_seen_variable_pressure_ = true;
        }
      }

      if (p <= 0.0) {
        pending_max_spike_ = false;
        if (!has_seen_real_pressure_) {
          in_stroke_ = true;
          last_emitted_pressure_ = legacy_default_pressure;
          return legacy_default_pressure;
        }
        const double soft = in_stroke_ ? std::min(last_emitted_pressure_, light_contact_floor) : light_contact_floor;
        in_stroke_ = true;
        last_emitted_pressure_ = soft;
        return soft;
      }

      if (pending_max_spike_) {
        pending_max_spike_ = false;
        // Confirmed sustained hard press on the next sample (4-8ms later): emit immediately.
        if (p >= confirm_high_threshold) {
          in_stroke_ = true;
          last_emitted_pressure_ = p;
          return p;
        }
        // Previous sample was an isolated single-frame spike to max; emit current normal sample.
        in_stroke_ = true;
        last_emitted_pressure_ = p;
        return p;
      }

      // Single-sample guard against isolated client-clamped 1.0 spikes mid-stroke or on onset.
      if (has_seen_variable_pressure_ && p >= max_spike_threshold) {
        const bool sudden_mid_stroke =
          in_stroke_ &&
          last_emitted_pressure_ < high_baseline_threshold &&
          (p - last_emitted_pressure_) >= sudden_jump_delta;
        const bool sudden_onset = !in_stroke_;
        if (sudden_mid_stroke || sudden_onset) {
          pending_max_spike_ = true;
          if (!in_stroke_) {
            in_stroke_ = true;
            last_emitted_pressure_ = light_contact_floor;
          }
          return last_emitted_pressure_;
        }
      }

      in_stroke_ = true;
      last_emitted_pressure_ = p;
      return p;
    }

  private:
    bool in_stroke_ {};
    bool has_seen_real_pressure_ {};
    bool has_seen_variable_pressure_ {};
    bool has_seen_normal_tilt_ {};
    bool pending_max_spike_ {};
    double last_emitted_pressure_ {};
  };

}  // namespace platf::macos_input_policy
