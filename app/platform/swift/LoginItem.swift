import AppKit
import ServiceManagement

/// "Open at login" -- registering the app bundle itself with launchd, the
/// macOS 13+ way (`SMAppService`, no helper bundle, no `SMLoginItemSetEnabled`).
///
/// This matters more here than in an ordinary app. Hammerdeck's value is what it
/// does while nobody is looking at it: global hotkeys, schedules, and the
/// sleep/wake/screenLock rules. None of that survives a reboot unless something
/// starts the app, and because the menulet disappears along with it there is no
/// symptom to notice -- only shortcuts that quietly stop working.
///
/// **The OS owns this state, so it is read from the OS and never mirrored into a
/// `hammerdeck.*` default.** The user can switch the item off in System Settings
/// > General > Login Items, and macOS can move it to `.requiresApproval` on its
/// own; a cached copy would then show a switch state the machine does not have.
/// Same reasoning that keeps Sparkle's `automaticallyChecksForUpdates`
/// unmirrored in `Updater`.
///
/// Default OFF, and there is no code path that turns it on unasked: installing a
/// login item is a change to the user's machine that outlives the app being
/// open, so it is theirs to make.
@MainActor
enum LoginItem {

    /// Whether the control can do anything at all. launchd registers a BUNDLE,
    /// and an unbundled `swift run` has no bundle identifier -- the same tell
    /// `Diagnostics` uses to distinguish a dev run from the signed .app. Hidden
    /// rather than shown disabled, the call `StatusBar` already made for Check
    /// for Updates: a permanently dead switch reads as broken, not inapplicable.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// launchd will start the app at the next login.
    static var isEnabled: Bool { status == .enabled }

    /// Registered, but macOS is holding it behind the user's own approval in
    /// System Settings. A distinct state from both on and off, and the only one
    /// where the app has already done everything it can.
    static var needsApproval: Bool { status == .requiresApproval }

    /// Apply the switch. Returns nil on success, or a reason it did not take.
    ///
    /// Deliberately not a `try?` that swallows: registration genuinely fails --
    /// an unsigned copy, or one sitting somewhere launchd will not accept -- and
    /// a switch that springs back with no explanation is the silent-operation
    /// failure this app has already been caught by more than once.
    static func set(_ on: Bool) -> String? {
        do {
            if on {
                // register() on an already-registered service throws, and the
                // approval state counts as registered.
                guard status != .enabled, status != .requiresApproval else { return nil }
                try SMAppService.mainApp.register()
            } else {
                guard status != .notRegistered else { return nil }
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Open System Settings on the pane that owns the approval, so the user is
    /// not asked to go hunting for a list whose name changes between releases.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
