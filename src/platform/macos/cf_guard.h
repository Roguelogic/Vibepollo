/**
 * @file src/platform/macos/cf_guard.h
 * @brief Lightweight RAII ownership wrapper for CoreFoundation / CoreGraphics references.
 */
#pragma once

#include <CoreFoundation/CoreFoundation.h>

namespace platf {

  template <class T>
  class cf_ref_t {
  public:
    cf_ref_t() noexcept = default;
    explicit cf_ref_t(T ref) noexcept :
        ref_(ref) {}
    ~cf_ref_t() noexcept {
      reset();
    }

    cf_ref_t(const cf_ref_t &) = delete;
    cf_ref_t &operator=(const cf_ref_t &) = delete;

    cf_ref_t(cf_ref_t &&other) noexcept :
        ref_(other.release()) {}
    cf_ref_t &operator=(cf_ref_t &&other) noexcept {
      if (this != &other) {
        reset(other.release());
      }
      return *this;
    }

    void reset(T next = nullptr) noexcept {
      if (ref_ == next) {
        return;
      }
      if (ref_ != nullptr) {
        CFRelease(ref_);
      }
      ref_ = next;
    }

    T release() noexcept {
      const T tmp = ref_;
      ref_ = nullptr;
      return tmp;
    }

    [[nodiscard]] T get() const noexcept {
      return ref_;
    }

    explicit operator bool() const noexcept {
      return ref_ != nullptr;
    }

  private:
    T ref_ = nullptr;
  };

}  // namespace platf
