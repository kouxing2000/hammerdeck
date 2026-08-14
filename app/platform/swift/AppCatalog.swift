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
    /// Backed by the same plain directory scan the app_launcher feature uses
    /// (`Native.scanInstalledApps`) -- deliberately NOT Spotlight: an
    /// `NSMetadataQuery` returns nothing when indexing is disabled, precisely the
    /// environment app_launcher exists to serve, and it silently left this picker
    /// empty there. One enumerator, one answer to "what is installed". Sorted by
    /// name for the picker; sync (measured ~120ms cold, ~1ms warm).
    static func installedApps() -> [(name: String, bundleId: String)] {
        Native.scanInstalledApps()
            .map { (name: $0.name, bundleId: $0.bundleId) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
