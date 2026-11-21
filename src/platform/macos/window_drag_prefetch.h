/**
 * @file src/platform/macos/window_drag_prefetch.h
 * @brief Asynchronous window drag-region prefetch coordinator for touch and Apple Pencil down events.
 */
#pragma once

#include <array>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <mutex>
#include <optional>
#include <thread>
#include <utility>

namespace platf::window_drag_prefetch {

  struct point_t {
    double x {};
    double y {};

    constexpr bool operator==(const point_t &) const noexcept = default;
  };

  struct ticket_t {
    std::uint64_t request_id {};
    point_t point {};
    std::uint64_t layout_epoch {};
    std::chrono::steady_clock::time_point started_at {};

    [[nodiscard]] constexpr explicit operator bool() const noexcept {
      return request_id != 0;
    }

    constexpr void reset() noexcept {
      *this = {};
    }
  };

  enum class resolution_source_e : std::uint8_t {
    prefetched_ready,
    prefetched_waited,
    sync_fallback,
  };

  struct resolution_t {
    bool is_drag_region {};
    resolution_source_e source {resolution_source_e::sync_fallback};
  };

  /**
   * @brief Single-worker latest-wins prefetcher that hides synchronous WindowServer window-list
   *        queries behind the physical travel time between touch/pen DOWN and crossing drag slop.
   */
  class coordinator_t {
  public:
    using query_fn_t = std::function<bool(point_t)>;
    using worker_init_fn_t = std::function<void()>;

    coordinator_t() = default;

    coordinator_t(query_fn_t query_fn, worker_init_fn_t worker_init_fn = {}) {
      start_worker(std::move(query_fn), std::move(worker_init_fn));
    }

    coordinator_t(const coordinator_t &) = delete;
    coordinator_t &operator=(const coordinator_t &) = delete;

    ~coordinator_t() {
      stop_worker();
    }

    void start_worker(query_fn_t query_fn, worker_init_fn_t worker_init_fn = {}) {
      stop_worker();
      {
        std::lock_guard lock {_mutex};
        _query_fn = std::move(query_fn);
        _stopping = false;
        _pending.reset();
        _in_progress_id = 0;
        _completed = {};
      }
      if (_query_fn) {
        _worker = std::thread(&coordinator_t::run_worker, this, std::move(worker_init_fn));
      }
    }

    void stop_worker() {
      {
        std::lock_guard lock {_mutex};
        _stopping = true;
        _pending.reset();
      }
      _work_cv.notify_all();
      _done_cv.notify_all();
      if (_worker.joinable()) {
        _worker.join();
      }
    }

    [[nodiscard]] ticket_t begin(
      const point_t pt,
      const std::uint64_t layout_epoch,
      const std::chrono::steady_clock::time_point now
    ) {
      std::uint64_t id = 0;
      {
        std::lock_guard lock {_mutex};
        if (_stopping || !_query_fn) {
          return {};
        }
        id = ++_next_request_id;
        _pending = request_t {id, pt};
      }
      _work_cv.notify_one();
      return ticket_t {id, pt, layout_epoch, now};
    }

    void cancel(ticket_t &ticket) {
      if (!ticket) {
        return;
      }
      {
        std::lock_guard lock {_mutex};
        if (_pending && _pending->id == ticket.request_id) {
          _pending.reset();
        }
      }
      ticket.reset();
    }

    [[nodiscard]] resolution_t resolve(
      ticket_t &ticket,
      const point_t pt,
      const std::uint64_t current_layout_epoch,
      const std::chrono::steady_clock::time_point now,
      const std::chrono::steady_clock::duration max_age = std::chrono::milliseconds(350),
      const std::chrono::steady_clock::duration in_flight_wait_budget = std::chrono::milliseconds(5)
    ) {
      const ticket_t local = ticket;
      ticket.reset();

      query_fn_t fallback_fn;
      const bool valid_context =
        local &&
        local.point == pt &&
        local.layout_epoch == current_layout_epoch &&
        now >= local.started_at &&
        (now - local.started_at) <= max_age;

      {
        std::unique_lock lock {_mutex};
        fallback_fn = _query_fn;
        if (!valid_context) {
          if (_pending && _pending->id == local.request_id) {
            _pending.reset();
          }
        } else {
          const auto &slot = _completed[local.request_id & (completed_ring_size - 1)];
          if (slot.id == local.request_id) {
            return resolution_t {slot.is_drag_region, resolution_source_e::prefetched_ready};
          }

          if (_in_progress_id == local.request_id &&
              in_flight_wait_budget > std::chrono::steady_clock::duration::zero()) {
            _done_cv.wait_for(lock, in_flight_wait_budget, [&] {
              return _stopping || _completed[local.request_id & (completed_ring_size - 1)].id == local.request_id;
            });
            const auto &waited_slot = _completed[local.request_id & (completed_ring_size - 1)];
            if (waited_slot.id == local.request_id) {
              return resolution_t {waited_slot.is_drag_region, resolution_source_e::prefetched_waited};
            }
          }

          if (_pending && _pending->id == local.request_id) {
            _pending.reset();
          }
        }
      }

      const bool sync_result = fallback_fn ? fallback_fn(pt) : false;
      return resolution_t {sync_result, resolution_source_e::sync_fallback};
    }

  private:
    static constexpr std::size_t completed_ring_size = 4;

    struct request_t {
      std::uint64_t id {};
      point_t point {};
    };

    struct completed_t {
      std::uint64_t id {};
      bool is_drag_region {};
    };

    void run_worker(worker_init_fn_t worker_init_fn) {
      if (worker_init_fn) {
        worker_init_fn();
      }

      for (;;) {
        request_t req {};
        query_fn_t query;
        {
          std::unique_lock lock {_mutex};
          _work_cv.wait(lock, [&] {
            return _stopping || _pending.has_value();
          });
          if (_stopping) {
            return;
          }
          req = *_pending;
          _pending.reset();
          _in_progress_id = req.id;
          query = _query_fn;
        }

        const bool result = query ? query(req.point) : false;

        {
          std::lock_guard lock {_mutex};
          _completed[req.id & (completed_ring_size - 1)] = completed_t {req.id, result};
          if (_in_progress_id == req.id) {
            _in_progress_id = 0;
          }
        }
        _done_cv.notify_all();
      }
    }

    std::mutex _mutex;
    std::condition_variable _work_cv;
    std::condition_variable _done_cv;
    std::thread _worker;
    query_fn_t _query_fn;
    bool _stopping {false};
    std::uint64_t _next_request_id {0};
    std::optional<request_t> _pending;
    std::uint64_t _in_progress_id {0};
    std::array<completed_t, completed_ring_size> _completed {};
  };

}  // namespace platf::window_drag_prefetch
