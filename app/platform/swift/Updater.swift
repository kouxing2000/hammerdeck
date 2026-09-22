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

    /// The feed actually in use, when it is NOT the one packaged into this build --
    /// otherwise nil.
    ///
    /// Sparkle resolves `SUFeedURL` from the host's user defaults BEFORE the
    /// Info.plist (`SUHost -objectForKey:ofClass:`), so `defaults write
    /// com.peach-studio.hammerdeck SUFeedURL ...` redirects any packaged copy at
    /// another feed. Nothing we ship does that -- there is one feed, and a
    /// pre-release is a CHANNEL within it -- but the capability is Sparkle's and
    /// exists whether or not we use it, which is exactly why this is here.
    ///
    /// It is deliberately read back through Sparkle's `feedURL` rather than from
    /// UserDefaults directly: Sparkle owns the resolution order (delegate, then
    /// defaults, then plist), and a second reader here would eventually disagree
    /// with the one doing the polling.
    ///
    /// The redirect survives an update and outlives the reason for it, and a
    /// machine left on another feed looks completely normal right up until it
    /// silently stops being offered real releases -- so Settings shows this
    /// whenever it is set, with a way back. There is no UI to turn it ON: a
    /// foreign feed can advertise a version above every real release, and a
    /// copy that accepted one would never be offered a genuine version again.
    /// Trying a build early is `receivesBeta` instead, which selects a channel
    /// within this same feed and stays additive.
    var testFeedHost: String? {
        guard let effective = controller?.updater.feedURL else { return nil }
        // Both sides through URL parsing before comparing: the plist holds a
        // string and Sparkle hands back a parsed URL, so a difference in
        // encoding or a trailing slash would otherwise read as a redirect that
        // nobody made.
        let packaged = Updater.feedURL.flatMap(URL.init(string:))
        guard effective.absoluteString != packaged?.absoluteString else { return nil }
        return effective.host ?? effective.absoluteString
    }

    /// Drop a defaults-set feed, returning the app to the one it was built with.
    /// Sparkle's own API, which knows which defaults domain the host reads.
    func usePackagedFeed() {
        controller?.updater.clearFeedURLFromUserDefaults()
    }

    /// Background update checks. Sparkle persists this itself in the app's
    /// UserDefaults domain, so there is no separate preference to keep in sync --
    /// deliberately NOT mirrored into a `hammerdeck.*` key, which would create two
    /// sources of truth that drift.
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Whether this copy is subscribed to the `beta` channel.
    ///
    /// One feed, two kinds of entry: a release carries no `<sparkle:channel>` and
    /// every copy sees it, while a candidate carries `beta` and only a subscriber
    /// does. Sparkle always includes the default channel in the allowed set, so
    /// turning this on ADDS the candidates rather than trading the real releases
    /// away -- which is exactly what redirecting `SUFeedURL` at another host would
    /// have done.
    ///
    /// Stored under our own key rather than mirrored from Sparkle, because unlike
    /// `automaticallyChecks` there is no Sparkle-owned property behind it: the
    /// delegate below is asked on every check and this key is its only input.
    var receivesBeta: Bool {
        get { UserDefaults.standard.bool(forKey: Updater.betaChannelKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Updater.betaChannelKey)
            // Sparkle re-cycles itself when `automaticallyChecksForUpdates` or the
            // interval change; a delegate-driven change is invisible to it, so
            // without this the new channel first applies up to a day later.
            controller?.updater.resetUpdateCycle()
        }
    }

    /// `nonisolated` so the delegate below and its tests can read it without
    /// hopping to the main actor. It is an immutable string; there is nothing to
    /// isolate.
    nonisolated static let betaChannelKey = "hammerdeck.updates.beta"

    private let controller: SPUStandardUpdaterController?
    /// Strongly held on purpose: `SPUStandardUpdaterController` declares
    /// `updaterDelegate` `__weak` and its header makes keeping it alive the
    /// caller's job. Passed as a temporary it would deallocate before the first
    /// check, and the failure is silent -- no delegate method is ever called, so
    /// the beta toggle would appear to do nothing at all and no update cycle
    /// would ever reach the daily log.
    private let delegate: UpdaterDelegate

    private init() {
        let delegate = UpdaterDelegate()
        self.delegate = delegate
        guard Updater.feedURL != nil else {
            controller = nil
            return
        }
        // startingUpdater: true schedules the background check loop immediately.
        // The feed and the key still come from the Info.plist rather than from
        // code; the delegate only picks channels and logs what each cycle did.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: delegate,
                                                  userDriverDelegate: nil)
    }

    /// User-initiated check. Shows Sparkle's UI, including "you're up to date",
    /// which a background check deliberately stays silent about.
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}

/// What Sparkle asks us and tells us: which channels this copy may find updates
/// in, and -- for the daily log -- what each update cycle found and how it ended.
///
/// It holds no state of its own: the defaults key is read on demand, so the answer
/// cannot go stale against a toggle the user just flipped. (`SPUUpdaterDelegate` is
/// declared `NS_SWIFT_UI_ACTOR`, so Sparkle always calls on the main thread -- the
/// on-demand read is about staleness, not about threading.)
/// Every `SPUUpdaterDelegate` method is OPTIONAL, so a method that does not match
/// the requirement satisfies the conformance vacuously: it compiles without even a
/// warning and is never called, which looks exactly like the weak-reference
/// failure above. Two things hold the line. The explicit selectors survive a
/// rename of the Swift methods (and the compiler rejects one outright if it is
/// ever changed to something the protocol does not declare), and
/// `UpdaterDelegateTests` asserts `responds(to:)` for the case the compiler stays
/// silent about. Internal, not private, so that test can reach it.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    @objc(allowedChannelsForUpdater:)
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        // The updater argument is unread: Sparkle passes it so one delegate can
        // serve several, and this app has one.
        UpdaterDelegate.allowed
    }

    /// Split out so the decision can be asserted without conjuring an `SPUUpdater`
    /// -- constructing a real one starts a background check against the live feed.
    static var allowed: Set<String> {
        // An empty set is not "no updates" -- Sparkle documents the default
        // channel as always included, so this is purely additive.
        UserDefaults.standard.bool(forKey: Updater.betaChannelKey) ? ["beta"] : []
    }

    /// Each update cycle's outcome, into the daily log.
    ///
    /// Sparkle's own logging goes to the unified log under ITS subsystem, which no
    /// bug report attaches and "Open Logs" never shows -- and a BACKGROUND check
    /// that fails is invisible to the user by design: Sparkle only shows an error
    /// when the check was user-initiated or an update was already on screen. This
    /// line is therefore the only readable trace of a 404 feed, a dead network or a
    /// signature rejection. The user-facing half needs nothing from us: a check from
    /// the menu already gets Sparkle's error alert, and a background one stays
    /// silent, which is what it should do.
    ///
    /// Sparkle skips this call only when a cycle ends by immediately starting the
    /// next one (an already-downloaded automatic update), which is never a failure.
    /// The success lines are kept too, not only the failures: a background check
    /// runs about once a day, and "checked, nothing newer" is the only thing that
    /// tells a quiet log apart from an updater that never ran.
    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor check: SPUUpdateCheck, error: Error?) {
        Native.shared.seamLog(UpdaterDelegate.cycleLogLine(check: check, error: error as NSError?))
    }

    /// Logged on its own because a cycle that finds an update ends with no error
    /// whether the user installed it or dismissed it -- without this line the
    /// finish line alone cannot say an update was ever offered.
    @objc(updater:didFindValidUpdate:)
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Native.shared.seamLog("update check: found \(item.displayVersionString) (build \(item.versionString))")
    }

    /// Split out for the same reason as `allowed`: the wording can be asserted
    /// without a live `SPUUpdater`.
    nonisolated static func cycleLogLine(check: SPUUpdateCheck, error: NSError?) -> String {
        let kind: String
        switch check {
        case .updates: kind = "user-initiated"
        case .updatesInBackground: kind = "background"
        case .updateInformation: kind = "information"
        @unknown default: kind = "kind \(check.rawValue)"
        }
        guard let error else { return "update check (\(kind)): finished" }
        if error.domain == SUSparkleErrorDomain {
            switch error.code {
            case Int(SUError.noUpdateError.rawValue):
                return "update check (\(kind)): " + noUpdateReason(error)
            case Int(SUError.installationCanceledError.rawValue),
                 Int(SUError.installationAuthorizeLaterError.rawValue):
                return "update check (\(kind)): install deferred by the user (\(error.code))"
            default: break
            }
        }
        // The top-level description is Sparkle's generic sentence ("An error
        // occurred in retrieving update information"); the cause -- the HTTP
        // status, the URL error, the validation failure -- is in the underlying
        // error.
        var line = "update check (\(kind)) FAILED: \(error.domain) \(error.code): \(error.localizedDescription)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            line += " -- caused by \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)"
        }
        return line
    }

    /// `SUNoUpdateError` also covers "a newer build exists, but not for this Mac"
    /// -- exactly the case behind "I never got the update" -- so it is only "up to
    /// date" when Sparkle says the copy is on or past the latest version.
    private nonisolated static func noUpdateReason(_ error: NSError) -> String {
        let raw = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value
        switch raw.flatMap(SPUNoUpdateFoundReason.init(rawValue:)) {
        case .onLatestVersion, .onNewerThanLatestVersion:
            return "up to date"
        case .systemIsTooOld:
            return "newer build exists but this macOS is too old for it"
        case .systemIsTooNew:
            return "newer build exists but this macOS is too new for it"
        case .hardwareDoesNotSupportARM64:
            return "newer build exists but this Mac cannot run it (no ARM64)"
        default:
            return "no update (reason \(raw.map(String.init) ?? "none"))"
        }
    }
}
