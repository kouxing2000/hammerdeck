// The candidate set + display-name resolution for an `appList` option, factored
// out of the SettingsView form so the view stays presentation-only. This is the
// one place that asks NSWorkspace which apps exist -- host-UI business logic,
// not feature-platform OS surface (Settings is host UI, so NSWorkspace is fair
// game here, same as the inline use it replaces).

import AppKit

enum AppCatalog {
    /// Currently-running regular (UI) apps as (display name, bundle id), deduped
    /// by bundle id and sorted -- the candidate set an `appList` menu offers.
    /// Read fresh each time the menu opens so it reflects what's running now.
    static func runningApps() -> [(name: String, bundleId: String)] {
        var seen = Set<String>()
        var out: [(name: String, bundleId: String)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let name = app.localizedName, let bid = app.bundleIdentifier,
                  !seen.contains(bid) else { continue }
            seen.insert(bid)
            out.append((name, bid))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// The display name for an installed app's bundle id, or nil when it can't be
    /// resolved (e.g. the app was uninstalled since it was chosen).
    static func displayName(forBundleId id: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return cleanAppName(FileManager.default.displayName(atPath: url.path))
    }

    /// Finder's display name honors the "Show all filename extensions" setting, so an
    /// app can come back as "Safari.app"; strip a trailing ".app" for a clean label
    /// that's also consistent with NSRunningApplication.localizedName (never suffixed).
    static func cleanAppName(_ s: String) -> String {
        s.hasSuffix(".app") ? String(s.dropLast(4)) : s
    }

    // NSCache is internally thread-safe but not marked Sendable; the access here is
    // all from the main thread (SwiftUI render) anyway.
    nonisolated(unsafe) private static let iconCache = NSCache<NSString, NSImage>()

    /// The app's Finder icon for a bundle id (the picker shows it next to each name),
    /// or nil when the bundle can't be located. Cached so re-rendering the list while
    /// the user types doesn't re-hit Launch Services + disk per row.
    static func icon(forBundleId id: String) -> NSImage? {
        if let hit = iconCache.object(forKey: id as NSString) { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        iconCache.setObject(img, forKey: id as NSString)
        return img
    }

    /// ALL installed apps as (display name, bundle id), regardless of whether they
    /// are running -- the candidate set the rules editor's app-target picker offers
    /// (so "Quit Slack at midnight" can be authored while Slack is closed).
    ///
    /// Discovered via Spotlight (`NSMetadataQuery`), the system's own application
    /// index: it covers every install location, not just `/Applications`, which a
    /// raw directory scan would miss (and which is the discouraged approach). The
    /// query is gathered once per session and cached, so this is `async` only on
    /// the first call. Display name comes from the bundle path (Finder's name),
    /// matching `NSRunningApplication.localizedName` -- the name-fallback the
    /// matcher uses when a rule has no bundle id.
    static func installedApps() async -> [(name: String, bundleId: String)] {
        await InstalledAppsIndex.shared.apps()
    }
}

/// Owns the one Spotlight query behind `AppCatalog.installedApps()`. Gathers once,
/// caches, and resumes any awaiters when the gather finishes. Kept tiny + private:
/// the only entry point is `apps()`.
@MainActor
private final class InstalledAppsIndex {
    static let shared = InstalledAppsIndex()

    private let query = NSMetadataQuery()
    private var cached: [(name: String, bundleId: String)] = []
    private var gathered = false
    private var waiters: [CheckedContinuation<[(name: String, bundleId: String)], Never>] = []

    // Spotlight's application-bundle predicate also returns background agents, XPC
    // helpers, and system services (AccessibilityUIServer, ABAssistantService, ...) --
    // none of which a user would write a "quit / frontmost app" rule about. Keep only
    // bundles that are real launchable apps: NOT nested inside another bundle
    // (".../Foo.app/Contents/.../Helper.app") and NOT buried in /System/Library
    // (CoreServices / PrivateFrameworks agents). This keeps /Applications,
    // /System/Applications (+ Utilities), and ~/Applications -- the user-facing set.
    private static func isUserFacingApp(_ path: String) -> Bool {
        !path.contains("/Contents/") && !path.hasPrefix("/System/Library/")
    }

    private init() {
        query.predicate = NSPredicate(format: "kMDItemContentTypeTree == 'com.apple.application-bundle'")
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { _ in MainActor.assumeIsolated { InstalledAppsIndex.shared.finish() } }
    }

    func apps() async -> [(name: String, bundleId: String)] {
        if gathered { return cached }
        if !query.isStarted {
            query.start()
            startTimeout()
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    // Spotlight can be disabled or stalled for a volume, in which case
    // DidFinishGathering never arrives and the awaiters would hang forever (the
    // "Finding apps…" spinner). Cap the wait: finalize with whatever has gathered so
    // far (often the complete set) so the picker degrades to running-apps + free-text
    // instead of spinning. A normal gather finishes well within this and no-ops it.
    private func startTimeout() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !self.gathered { self.finish() }
        }
    }

    private func finish() {
        guard !gathered else { return }
        query.disableUpdates()
        var seen = Set<String>()
        var out: [(name: String, bundleId: String)] = []
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let bid = item.value(forAttribute: "kMDItemCFBundleIdentifier") as? String,
                  !bid.isEmpty, !seen.contains(bid),
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  Self.isUserFacingApp(path)
            else { continue }
            seen.insert(bid)
            out.append((AppCatalog.cleanAppName(FileManager.default.displayName(atPath: path)), bid))
        }
        cached = out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        gathered = true
        query.stop()   // one-shot snapshot for the session; a restart re-gathers.
        let pending = waiters; waiters = []
        for w in pending { w.resume(returning: cached) }
    }
}
