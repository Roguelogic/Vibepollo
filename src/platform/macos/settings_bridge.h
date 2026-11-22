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
- (void)checkForUpdates;
- (void)restartHost;

@end

NS_ASSUME_NONNULL_END
#endif

#ifdef __cplusplus
extern "C" {
#endif

void vibepollo_register_macos_native_ui(void);
void vibepollo_open_macos_native_ui(const char * _Nullable route);

#ifdef __cplusplus
}
#endif
