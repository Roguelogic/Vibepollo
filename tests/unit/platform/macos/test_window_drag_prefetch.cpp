#include "src/platform/macos/window_drag_prefetch.h"

#include <atomic>
#include <chrono>
#include <future>
#include <gtest/gtest.h>
#include <thread>

using namespace std::chrono_literals;
using platf::window_drag_prefetch::coordinator_t;
using platf::window_drag_prefetch::point_t;
using platf::window_drag_prefetch::resolution_source_e;

TEST(MacosWindowDragPrefetch, ConsumesReadyPrefetchWithoutSecondSynchronousQuery) {
  std::atomic<int> query_calls {0};
  std::promise<void> completed_once;
  auto completed_future = completed_once.get_future();

  coordinator_t prefetcher([&](const point_t pt) {
    if (++query_calls == 1) {
      completed_once.set_value();
    }
    return pt.y <= 54.0;
  });

  const auto t0 = std::chrono::steady_clock::now();
  auto ticket = prefetcher.begin({200.0, 24.0}, /*layout_epoch=*/7, t0);
  ASSERT_TRUE(ticket);
  ASSERT_EQ(completed_future.wait_for(1s), std::future_status::ready);

  // Wait briefly for the worker to publish completion after query return.
  std::this_thread::sleep_for(2ms);

  const auto res = prefetcher.resolve(ticket, {200.0, 24.0}, /*current_layout_epoch=*/7, t0 + 16ms);
  EXPECT_FALSE(ticket);
  EXPECT_TRUE(res.is_drag_region);
  EXPECT_EQ(res.source, resolution_source_e::prefetched_ready);
  EXPECT_EQ(query_calls.load(), 1);
}

TEST(MacosWindowDragPrefetch, JoinsAlreadyInFlightQueryInsteadOfIssuingDuplicateWindowServerCall) {
  std::atomic<int> query_calls {0};
  std::promise<void> entered_worker;
  auto entered_future = entered_worker.get_future();
  std::promise<void> finish_worker;
  auto finish_future = finish_worker.get_future().share();

  coordinator_t prefetcher([&](const point_t pt) {
    ++query_calls;
    entered_worker.set_value();
    finish_future.wait();
    return pt.x > 500.0;
  });

  const auto t0 = std::chrono::steady_clock::now();
  auto ticket = prefetcher.begin({640.0, 120.0}, /*layout_epoch=*/3, t0);
  ASSERT_EQ(entered_future.wait_for(1s), std::future_status::ready);

  std::thread releaser([&] {
    std::this_thread::sleep_for(2ms);
    finish_worker.set_value();
  });

  const auto res = prefetcher.resolve(ticket, {640.0, 120.0}, /*current_layout_epoch=*/3, t0 + 1ms, 350ms, 50ms);
  releaser.join();

  EXPECT_TRUE(res.is_drag_region);
  EXPECT_EQ(res.source, resolution_source_e::prefetched_waited);
  EXPECT_EQ(query_calls.load(), 1);
}

TEST(MacosWindowDragPrefetch, FallsBackToSynchronousQueryWhenLayoutChangesOrResultExpiresOrWorkerIsBusy) {
  // 1. Layout epoch change invalidates even a completed prefetch.
  {
    std::atomic<bool> drag_now {true};
    std::atomic<int> calls {0};
    std::promise<void> done;
    auto done_future = done.get_future();

    coordinator_t prefetcher([&](const point_t) {
      const int n = ++calls;
      const bool val = drag_now.load();
      if (n == 1) {
        done.set_value();
      }
      return val;
    });

    const auto t0 = std::chrono::steady_clock::now();
    auto ticket = prefetcher.begin({100.0, 20.0}, /*layout_epoch=*/10, t0);
    ASSERT_EQ(done_future.wait_for(1s), std::future_status::ready);
    std::this_thread::sleep_for(2ms);

    // Simulate window moving away before crossing slop, bumping layout_epoch 10 -> 11.
    drag_now.store(false);
    const auto res = prefetcher.resolve(ticket, {100.0, 20.0}, /*current_layout_epoch=*/11, t0 + 20ms);
    EXPECT_FALSE(res.is_drag_region);
    EXPECT_EQ(res.source, resolution_source_e::sync_fallback);
    EXPECT_EQ(calls.load(), 2);
  }

  // 2. Expired age (> max_age) falls back to synchronous query.
  {
    std::atomic<int> calls {0};
    coordinator_t prefetcher([&](const point_t) {
      return (++calls == 2);
    });

    const auto t0 = std::chrono::steady_clock::now();
    auto ticket = prefetcher.begin({100.0, 20.0}, /*layout_epoch=*/1, t0);
    std::this_thread::sleep_for(5ms);

    const auto res = prefetcher.resolve(ticket, {100.0, 20.0}, /*current_layout_epoch=*/1, t0 + 400ms, 300ms);
    EXPECT_TRUE(res.is_drag_region);
    EXPECT_EQ(res.source, resolution_source_e::sync_fallback);
    EXPECT_EQ(calls.load(), 2);
  }

  // 3. Worker busy with an earlier cancelled touch falls back immediately and cancels queued duplicate.
  {
    std::atomic<int> calls {0};
    std::promise<void> first_entered;
    auto first_entered_future = first_entered.get_future();
    std::promise<void> unblock_first;
    auto unblock_first_future = unblock_first.get_future().share();

    coordinator_t prefetcher([&](const point_t pt) {
      const int n = ++calls;
      if (n == 1) {
        first_entered.set_value();
        unblock_first_future.wait();
      }
      return pt.x == 42.0;
    });

    const auto t0 = std::chrono::steady_clock::now();
    auto stale_ticket = prefetcher.begin({10.0, 10.0}, 1, t0);
    ASSERT_EQ(first_entered_future.wait_for(1s), std::future_status::ready);
    prefetcher.cancel(stale_ticket);

    auto second_ticket = prefetcher.begin({42.0, 10.0}, 1, t0 + 2ms);
    const auto res = prefetcher.resolve(second_ticket, {42.0, 10.0}, 1, t0 + 3ms);
    EXPECT_TRUE(res.is_drag_region);
    EXPECT_EQ(res.source, resolution_source_e::sync_fallback);

    unblock_first.set_value();
    std::this_thread::sleep_for(5ms);
    // Only the first in-flight query and the synchronous fallback ran; the cancelled pending request did not!
    EXPECT_EQ(calls.load(), 2);
  }
}
