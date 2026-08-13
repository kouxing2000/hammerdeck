import AppKit
import Sparkle

/// Sparkle auto-update, wrapped so the rest of the app never imports Sparkle.
///
/// This is HOST LIFECYCLE, not plugin surface: it is deliberately absent from
/// `ctx`, so no feature can reach it. Updating the app is something the host does
/// to itself, in the same category as the menubar and the Dock policy.
///
/// **Unavailable in a dev `swift run`, by design.** `SUFeedURL` and
/// `SUPublicEDKey` are written into the packaged Info.plist by
/// `scripts/package.sh`, so an unbundled binary has no feed and no public key.
/// Starting Sparkle there would leave it checking a nil feed and logging errors
/// on a timer for the whole session. The same read-the-plist-or-fall-back shape
/// `AppInfo` uses for the display name applies here, except the fallback is
/// "there is no updater" rather than a literal.
@MainActor
final class Updater {
    static let shared = Updater()

    /// The packaged feed. nil means unbundled (dev), which is the only supported
    /// reason to be without one -- a packaged build always carries it.
    static var feedURL: String? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    /// Whether an updater exists at all. Callers must branch on this before
    /// showing update UI; a dev run has none.
    var isAvailable: Bool { controller != nil }

    /// Sparkle's own gate on whether a check can be started right now (it is false
    /// while a check is already running, or while an install is pending). Suitable
    /// for menu-item validation, which is what Sparkle's headers recommend it for.
    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// Background update checks. Sparkle persists this itself in the app's
    /// UserDefaults domain, so there is no separate preference to keep in sync --
    /// deliberately NOT mirrored into a `hammerdeck.*` key, which would create two
    /// sources of truth that drift.
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    private let controller: SPUStandardUpdaterController?

    private init() {
        guard Updater.feedURL != nil else {
            controller = nil
            return
        }
        // startingUpdater: true schedules the background check loop immediately.
        // No delegates: the default user driver shows Sparkle's standard UI, and
        // the feed/key both come from the Info.plist rather than from code.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    /// User-initiated check. Shows Sparkle's UI, including "you're up to date",
    /// which a background check deliberately stays silent about.
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}
