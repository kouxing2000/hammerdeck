#import "HammerdeckNotify.h"

// NSUserNotification is deprecated (macOS 11) but still functional and, unlike
// UNUserNotificationCenter, needs NO permission prompt and delivers reliably from
// a locally-run / ad-hoc-signed app outside /Applications -- exactly why
// Hammerspoon's hs.notify still uses it. The deprecation is suppressed HERE (an
// ObjC pragma, the same pattern as Hammerspoon's libnotify.m) so the rest of the
// Swift codebase stays warning-free.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// A delegate that forces the banner to show even when Hammerdeck is the frontmost
// app (NSUserNotification suppresses it otherwise) -- so the Test button shows a
// real notification even while Settings is focused. Matches hs.notify's
// shouldPresentNotification override. Retained for the process lifetime.
@interface HDNotificationPresenter : NSObject <NSUserNotificationCenterDelegate>
@end

@implementation HDNotificationPresenter
- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center
     shouldPresentNotification:(NSUserNotification *)notification {
    return YES;
}
@end

static HDNotificationPresenter *gPresenter = nil;

BOOL HDPostSystemNotification(NSString *title, NSString *text) {
    // Notification Center attributes a notification to the running app's bundle;
    // a bare `swift run` binary has no bundle id, so bail and let the caller fall
    // back to the in-app banner.
    if (NSBundle.mainBundle.bundleIdentifier == nil) {
        return NO;
    }

    NSUserNotificationCenter *center = [NSUserNotificationCenter defaultUserNotificationCenter];
    if (gPresenter == nil) {
        gPresenter = [[HDNotificationPresenter alloc] init];
        center.delegate = gPresenter;
    }

    NSUserNotification *n = [[NSUserNotification alloc] init];
    n.title = title;
    if (text.length > 0) {
        n.informativeText = text;
    }
    [center deliverNotification:n];
    return YES;
}

#pragma clang diagnostic pop
