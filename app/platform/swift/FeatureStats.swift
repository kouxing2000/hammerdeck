import AppKit

/// Opt-in feature statistics, carried by the daily update check.
///
/// Off until the user says yes -- once, in `askOnceIfDue`, or with the switch in
/// Settings > General. When on, Sparkle appends the four kinds of data the user
/// agreed to, in five fields, to every feed request (the daily check and "Check for
/// Updates" alike): a random install ID (`hd_id`), the macOS version (`hd_os`), the
/// built-in features switched on (`hd_on`), and how often the user fired each on the newest
/// complete day with use, in buckets, with that day's date (`hd_use` + `hd_day`).
/// They land in the website's request log; there is no other endpoint. The counting lives in Lua
/// (`platform/feature_stats.lua`), at the registry's fire sites.
///
/// Absent wherever the updater is: with no update check there is nothing to carry
/// the fields, so a dev `swift run` neither asks nor shows the switch.
@MainActor
enum FeatureStats {
    nonisolated static let shareKey  = "hammerdeck.stats.share"
    nonisolated static let idKey     = "hammerdeck.stats.id"
    nonisolated static let askedKey  = "hammerdeck.stats.asked"
    /// Written by `feature_stats.lua` (its COUNTS_KEY); cleared here when sharing
    /// stops or the ID is reset, so a new ID never inherits the old counts.
    nonisolated static let countsKey = "hammerdeck.stats.counts"

    static var isSharing: Bool { UserDefaults.standard.bool(forKey: shareKey) }

    /// The user's answer, from the ask or the switch. Either one counts as having
    /// been asked, so a user who already decided in Settings is never asked again.
    /// Turning it off forgets the ID and the counts, so sharing again later starts
    /// a copy the server cannot tie to the earlier one.
    static func setSharing(_ on: Bool) {
        let d = UserDefaults.standard
        d.set(on, forKey: shareKey)
        d.set(true, forKey: askedKey)
        if on {
            _ = installID()
        } else {
            d.removeObject(forKey: idKey)
            d.removeObject(forKey: countsKey)
        }
        Native.shared.seamLog("feature stats: sharing \(on ? "on" : "off")")
    }

    /// Made the first time it is needed and kept until `resetID`.
    static func installID() -> String {
        let d = UserDefaults.standard
        if let id = d.string(forKey: idKey), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        d.set(id, forKey: idKey)
        return id
    }

    static func resetID() {
        let d = UserDefaults.standard
        d.set(UUID().uuidString.lowercased(), forKey: idKey)
        d.removeObject(forKey: countsKey)
        Native.shared.seamLog("feature stats: install ID reset")
    }

    /// The fields for one update check; empty unless the user opted in. Lua
    /// answers nil when sharing is off, so the two gates cannot disagree in the
    /// direction that sends data. A report that fails sends nothing at all.
    static func parameters(osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                           report: @MainActor () throws -> [String: Any]? = registryReport) -> [[String: String]] {
        guard isSharing else {
            Native.shared.seamLog("feature stats: not shared with this update check (off)")
            return []
        }
        let r: [String: Any]
        do {
            guard let got = try report() else {
                Native.shared.seamLog("feature stats: not shared with this update check (no report from Lua)")
                return []
            }
            r = got
        } catch {
            Native.shared.seamLog("feature stats: not shared with this update check -- report failed: \(error)")
            return []
        }
        var fields: [(String, String)] = [
            ("hd_id", installID()),
            ("hd_os", "\(osVersion.majorVersion).\(osVersion.minorVersion)"),
            ("hd_on", r["on"] as? String ?? ""),
        ]
        if let day = r["day"] as? String, let use = r["use"] as? String {
            fields += [("hd_day", day), ("hd_use", use)]
        }
        let on = (r["on"] as? String ?? "").split(separator: ",").count
        Native.shared.seamLog("feature stats: update check carries id, os, \(on) features on, "
                              + "use for \(r["day"] as? String ?? "no complete day yet")")
        return fields.map { ["key": $0.0, "value": $0.1] }
    }

    private static func registryReport() throws -> [String: Any]? {
        try Native.shared.lua.call("platform.registry", "statsReport").first as? [String: Any]
    }

    /// Ask once, ever, on a launch after the first. Not on the first launch, which
    /// already asks for Accessibility; a second permission-style question there
    /// competes with the one the window features need. "Not Now" is the default
    /// button, and either answer is final -- the switch in Settings changes it.
    static func askOnceIfDue(isFirstRun: Bool) {
        let d = UserDefaults.standard
        guard Updater.shared.isAvailable, !isFirstRun, !d.bool(forKey: askedKey) else { return }
        // After launch settles, so the question does not land on top of the boot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            // Another dialog up (the crash-report offer runs at launch too): ask
            // on a later launch rather than stack a second question on it.
            guard !d.bool(forKey: askedKey), NSApp.modalWindow == nil else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = Strings.t("stats.ask.title", default: "Share feature statistics?")
            alert.informativeText = Strings.t("stats.ask.detail",
                default: "It helps decide what to improve. With each update check, Hammerdeck "
                       + "would also send which features are on, roughly how often each was used, "
                       + "your macOS version and a random ID you can reset -- never window titles, "
                       + "app names, websites or anything you type. Like any request, the update "
                       + "check reaches our website's log with your IP address. You can change "
                       + "this at any time in Settings > General.")
            alert.addButton(withTitle: Strings.t("stats.ask.no", default: "Not Now"))
            alert.addButton(withTitle: Strings.t("stats.ask.yes", default: "Share"))
            let share = alert.runModal() == .alertSecondButtonReturn
            setSharing(share)
            Native.shared.seamLog("feature stats: asked once, answer \(share ? "share" : "not now")")
        }
    }
}
