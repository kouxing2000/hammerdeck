import AppKit

// Self-owned UI surfaces for the native backend. We deliberately do NOT use
// UserNotifications here: it requires an app bundle + a permission prompt, and
// the M2 host is a bare SwiftPM executable. Our own floating panels need zero
// permissions and match the platform's overlay use cases (banner countdown,
// chooser dialogs). Revisit real Notification Center delivery in M3 when there
// is a signed .app bundle.

/// A borderless floating panel that can become key without activating the app
/// (so the chooser can take keystrokes while the user's app keeps focus).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
