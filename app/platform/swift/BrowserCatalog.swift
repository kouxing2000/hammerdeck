// Installed-browser + Chrome-profile enumeration and the Chromium check, used by
// the `siteList` Settings editor (which browser / profile to route a site to)
// and the open_site seam (Chromium-vs-not branch). Like AppCatalog, this is
// host-UI business logic -- the one place that asks LaunchServices which
// browsers exist and reads Chrome's profile list -- not feature-platform OS
// surface, so NSWorkspace / file reads are fair game.

import AppKit

enum BrowserCatalog {
    struct Browser: Identifiable, Hashable { let bundleId: String; let name: String; var id: String { bundleId } }
    struct Profile: Identifiable, Hashable { let dir: String; let name: String; var id: String { dir } }

    // Bundle ids whose browser supports `--app=` app windows and
    // `--profile-directory=` profile routing.
    private static let chromiumBundleIds: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
        "com.brave.Browser", "com.microsoft.edgemac",
        "org.chromium.Chromium", "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
    ]

    static func isChromium(_ bundleId: String) -> Bool { chromiumBundleIds.contains(bundleId) }

    /// Every installed app that can open an https URL, as (bundleId, name),
    /// deduped and sorted -- the candidate browsers a site can be routed to.
    static func installedBrowsers() -> [Browser] {
        guard let u = URL(string: "https://example.com") else { return [] }
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: u)
        var seen = Set<String>()
        var out: [Browser] = []
        for appURL in urls {
            guard let id = Bundle(url: appURL)?.bundleIdentifier, !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(Browser(bundleId: id, name: niceName(appURL)))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// The display name for a browser bundle id, or nil when it isn't installed.
    static func displayName(forBundleId id: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return niceName(url)
    }

    /// Chrome's profiles as (directory, friendly name) -- read from Chrome's
    /// `Local State` JSON (`profile.info_cache`). "Default" sorts first, then the
    /// numbered profiles. Empty when Chrome was never run / has no profiles.
    static func chromeProfiles() -> [Profile] {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        let out = cache.map { dir, v -> Profile in
            Profile(dir: dir, name: (v as? [String: Any])?["name"] as? String ?? dir)
        }
        return out.sorted { a, b in
            if a.dir == "Default" { return b.dir != "Default" }
            if b.dir == "Default" { return false }
            return a.dir.localizedStandardCompare(b.dir) == .orderedAscending
        }
    }

    /// The friendly profile name for a directory ("Profile 2" -> "peach"), or the
    /// directory itself when it can't be resolved.
    static func profileName(forDir dir: String) -> String {
        chromeProfiles().first { $0.dir == dir }?.name ?? dir
    }

    private static func niceName(_ appURL: URL) -> String {
        FileManager.default.displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}
