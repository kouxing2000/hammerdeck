#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Post a notification to the macOS Notification Center via the (deprecated but
/// permission-free) NSUserNotification API -- the same path Hammerspoon's
/// hs.notify uses. Isolated in this ObjC shim so the deprecation is suppressed
/// with a `#pragma` (clean in ObjC; fiddly in pure Swift), keeping the Swift
/// build warning-free.
///
/// Returns YES if it could post (there is an app bundle to attribute the
/// notification to), NO otherwise -- under a bare `swift run` there is no bundle,
/// so the Swift caller falls back to the in-app banner.
BOOL HDPostSystemNotification(NSString *title, NSString *_Nullable text);

NS_ASSUME_NONNULL_END
