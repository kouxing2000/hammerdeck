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
        return FileManager.default.displayName(atPath: url.path)
    }
}
