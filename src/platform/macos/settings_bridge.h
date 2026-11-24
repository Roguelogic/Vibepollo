/**
 * @file src/platform/macos/settings_bridge.h
 * @brief Pure Objective-C bridge between Vibepollo's C++ core and the native SwiftUI Settings window.
 */
#pragma once

#ifdef __OBJC__
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VibepolloHostBridge : NSObject

+ (instancetype)shared;

- (BOOL)isLoginWindowSession;
- (NSString *)appVersion;
- (NSString *)defaultHostName;
- (NSString *)webConsoleURL;
- (void)openWebConsoleInBrowser;

// Dashboard & Live Sessions
- (NSString *)fetchDashboardSnapshotJSON;
- (NSString *)fetchDashboardSnapshotJSONIncludingHostStats:(BOOL)includeHostStats
  NS_SWIFT_NAME(fetchDashboardSnapshotJSON(includeHostStats:));
- (void)openScreenCapturePrivacySettings;
- (void)openAccessibilityPrivacySettings;
- (BOOL)pairWithPIN:(NSString *)pin deviceName:(NSString *)deviceName;

// Paired Clients
- (NSString *)fetchClientsJSON;
- (BOOL)setClientEnabled:(NSString *)uuid enabled:(BOOL)enabled;
- (BOOL)disconnectClient:(NSString *)uuid;
- (BOOL)unpairClient:(NSString *)uuid;
- (BOOL)updateClientWithJSON:(NSString *)payloadJSON;

// Streaming Apps
- (NSString *)fetchAppsJSON;
- (BOOL)saveAppWithJSON:(NSString *)payloadJSON
           errorMessage:(NSString * _Nullable * _Nullable)errorMessage;
- (BOOL)deleteAppWithUUID:(NSString *)uuid;
- (void)terminateRunningApp;

// Host Settings & System Actions
- (NSString *)fetchSettingsJSON;
- (NSDictionary<NSString *, id> *)saveSettingsWithJSON:(NSString *)patchJSON;
- (BOOL)updateWebCredentialsWithUsername:(NSString *)username
                                password:(NSString *)password;
- (BOOL)isOpenAtLoginEnabled;
- (BOOL)isAllowOnLoginScreenEnabled;
- (BOOL)setOpenAtLogin:(BOOL)enabled;
- (BOOL)setAllowOnLoginScreen:(BOOL)enabled;

// Diagnostics, Session History & Integrations
- (NSString *)fetchLogsTail:(NSInteger)maxLines;
- (NSString *)currentLogFilePath;
- (void)revealLogFileInFinder;
- (NSString *)fetchSessionHistoryJSON:(NSInteger)limit;
- (BOOL)deleteSessionHistoryWithUUID:(NSString *)uuid;
- (BOOL)isSteamAvailable;
- (BOOL)syncSteamCatalogNow;

// Software Update (macOS System Settings > General > Software Update)
- (NSString *)fetchSoftwareUpdateStatusJSON;
- (void)checkForUpdates;
- (void)startSoftwareUpdateNow;
- (void)downloadSoftwareUpdateOnly;
- (void)cancelSoftwareUpdateDownload;
- (void)setSoftwareUpdateScheduledOnIdle:(BOOL)scheduled;
- (void)openExternalURL:(NSString *)urlString;
- (void)restartHost;

@end

NS_ASSUME_NONNULL_END
#endif

#ifdef __cplusplus
extern "C" {
#endif

void vibepollo_register_macos_native_ui(void);
void vibepollo_open_macos_native_ui(const char * _Nullable route);
void vibepollo_set_macos_native_ui_visible(_Bool visible);

#ifdef __cplusplus
}
#endif
