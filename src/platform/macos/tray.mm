/**
 * @file src/platform/macos/tray.mm
 * @brief Menu bar implementation of the tray API for macOS.
 *
 * Replaces third-party/tray/src/tray_darwin.m, which assumes it owns the process: its
 * tray_exit() calls [NSApp terminate:], skipping Vibepollo's shutdown, and its tray_update()
 * touches AppKit from whichever thread calls it. This keeps the same C API, but all AppKit
 * work happens on the main thread and tray_loop() returns instead of terminating.
 */
// standard includes
#include <atomic>
#include <csignal>
#include <string>
#include <vector>

// platform includes
#import <Cocoa/Cocoa.h>

// lib includes
#include <tray/src/tray.h>

// local includes
#include "misc.h"
#include "settings_bridge.h"

namespace {
  // Menu contents are copied when tray_update() is called: callers keep mutating their tray
  // structs afterwards, while the NSMenu is only rebuilt later on the main thread.
  struct menu_item_t {
    std::string text;
    bool disabled;
    bool checked;
    struct tray_menu *source;  ///< Handed back to its callback; system_tray.cpp keeps these static.
    std::vector<menu_item_t> submenu;
  };

  struct tray_snapshot_t {
    std::string icon;
    std::string tooltip;
    std::vector<menu_item_t> menu;
  };

  tray_log_callback log_callback = nullptr;
  std::atomic<bool> exit_requested = false;
  NSStatusItem *status_item = nil;

  void tray_log_message(enum tray_log_level level, NSString *message) {
    if (log_callback != nullptr) {
      log_callback(level, message.UTF8String);
    }
  }

  std::vector<menu_item_t> snapshot_menu(struct tray_menu *m) {
    std::vector<menu_item_t> items;
    for (; m != nullptr && m->text != nullptr; ++m) {
      items.push_back({m->text, m->disabled != 0, m->checked != 0, m, snapshot_menu(m->submenu)});
    }
    return items;
  }

  tray_snapshot_t snapshot(struct tray *tray) {
    return {
      tray->icon ? tray->icon : "",
      tray->tooltip ? tray->tooltip : "",
      snapshot_menu(tray->menu),
    };
  }
}  // namespace

@interface VibepolloTrayTarget: NSObject <NSApplicationDelegate>
@end

@implementation VibepolloTrayTarget

- (void)menuCallback:(NSMenuItem *)sender {
  auto *item = static_cast<struct tray_menu *>([sender.representedObject pointerValue]);
  if (item != nullptr && item->cb != nullptr) {
    item->cb(item);
  }
}

// Quit requests from the system (logout, Activity Monitor, a permission prompt's "Quit & Reopen")
// arrive as Apple Events. Route them through the SIGINT shutdown path instead of letting AppKit exit().
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
  std::raise(SIGINT);
  return NSTerminateCancel;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
  vibepollo_open_macos_native_ui(nullptr);
  return YES;
}

@end

namespace {
  VibepolloTrayTarget *target = nil;

  NSMenu *build_menu(const std::vector<menu_item_t> &items, bool top_level = true) {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    for (std::size_t idx = 0; idx < items.size(); ++idx) {
      const auto &item = items[idx];
      if (item.text == "-") {
        [menu addItem:[NSMenuItem separatorItem]];
        continue;
      }

      NSString *keyEq = @"";
      if (top_level && item.submenu.empty() && item.source != nullptr && item.source->cb != nullptr) {
        if (idx == 0) {
          keyEq = @",";
        } else if (idx + 1 == items.size()) {
          keyEq = @"q";
        }
      }
      NSMenuItem *menu_item = [[NSMenuItem alloc] initWithTitle:@(item.text.c_str())
                                                         action:@selector(menuCallback:)
                                                  keyEquivalent:keyEq];
      menu_item.target = target;
      menu_item.enabled = !item.disabled;
      menu_item.state = item.checked ? NSControlStateValueOn : NSControlStateValueOff;
      menu_item.representedObject = [NSValue valueWithPointer:item.source];
      if (!item.submenu.empty()) {
        menu_item.submenu = build_menu(item.submenu, false);
      }
      [menu addItem:menu_item];
    }
    return menu;
  }

  void apply(const tray_snapshot_t &state) {
    if (status_item == nil) {
      return;
    }

    // Template images let the menu bar tint the icon for light and dark appearances. If the SVG
    // doesn't load, use the icon's PNG rendering next to it.
    NSString *path = @(state.icon.c_str());
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
    if (image == nil && [path hasSuffix:@".svg"]) {
      NSString *png = [[path stringByDeletingPathExtension] stringByAppendingString:@"-16.png"];
      image = [[NSImage alloc] initWithContentsOfFile:png];
    }
    if (image != nil) {
      image.size = NSMakeSize(18, 18);
      [image setTemplate:YES];  // `template` is a C++ keyword, so no dot syntax

      status_item.button.image = image;
      status_item.button.title = @"";
    } else {
      tray_log_message(TRAY_LOG_WARNING, [NSString stringWithFormat:@"Failed to load tray icon %s", state.icon.c_str()]);
      status_item.button.image = nil;
      status_item.button.title = @(state.tooltip.c_str());
    }
    // Standard macOS menu bar extras never show hover tooltips; NSToolTipWindow (layer 103) can
    // also become stranded on screen across cursor warps or virtual display resolution changes.
    status_item.button.toolTip = nil;
    [status_item.button removeAllToolTips];
    status_item.button.accessibilityLabel = @(state.tooltip.c_str());
    for (NSWindow *window in NSApp.windows) {
      if (window != status_item.button.window &&
          [NSStringFromClass([window class]) containsString:@"ToolTip"]) {
        [window orderOut:nil];
      }
    }
    status_item.menu = build_menu(state.menu);
  }

  void remove_status_item() {
    if (status_item != nil) {
      [[NSStatusBar systemStatusBar] removeStatusItem:status_item];
      status_item = nil;
    }
  }
}  // namespace

void tray_set_log_callback(tray_log_callback cb) {
  log_callback = cb;
}

extern "C" void tray_ensure_macos_app_delegate(void) {
  auto install = ^{
    platf::ensure_appkit_session();
    vibepollo_register_macos_native_ui();
    if (target == nil) {
      target = [[VibepolloTrayTarget alloc] init];
      NSApp.delegate = target;
    }
  };
  if (NSThread.isMainThread) {
    install();
  } else {
    dispatch_async(dispatch_get_main_queue(), install);
  }
}

int tray_init(struct tray *tray) {
  if (!NSThread.isMainThread) {
    tray_log_message(TRAY_LOG_ERROR, @"tray_init() must be called on the main thread");
    return -1;
  }

  tray_ensure_macos_app_delegate();

  status_item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
  if (status_item == nil) {
    tray_log_message(TRAY_LOG_ERROR, @"Failed to create the menu bar status item");
    return -1;
  }

  exit_requested = false;
  apply(snapshot(tray));
  return 0;
}

int tray_loop(int blocking) {
  if (!exit_requested) {
    @autoreleasepool {
      // Even when blocking, wake periodically so callers can also watch their own shutdown state.
      NSDate *until = blocking ? [NSDate dateWithTimeIntervalSinceNow:0.5] : NSDate.distantPast;
      NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES];
      if (event != nil) {
        [NSApp sendEvent:event];
        [NSApp updateWindows];
      }
    }
  }

  if (exit_requested) {
    remove_status_item();
    return -1;
  }
  return 0;
}

void tray_update(struct tray *tray) {
  auto state = snapshot(tray);
  if (NSThread.isMainThread) {
    apply(state);
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    apply(state);
  });
}

void tray_exit(void) {
  exit_requested = true;
  if (NSThread.isMainThread) {
    remove_status_item();
  }

  // Wake a tray_loop() waiting in nextEventMatchingMask; postEvent is safe from any thread.
  if (NSApp != nil) {
    NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                       location:NSZeroPoint
                                  modifierFlags:0
                                      timestamp:0
                                   windowNumber:0
                                        context:nil
                                        subtype:0
                                          data1:0
                                          data2:0];
    [NSApp postEvent:wake atStart:YES];
  }
}
