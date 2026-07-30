// The editor for a `siteList` option (Quick Sites). Renders the configured
// sites as an expandable list: each row is a calm one-line summary (favicon,
// name, URL, a quiet browser/profile/app summary) that expands inline into a
// full-width labeled form. Replaces the old `Name | URL | app` text box.
// Persisted as a JSON array of SiteRow; legacy text configs decode into rows on
// first open (one-time migration on next edit).

import SwiftUI

// One configured site. Stored as JSON -- `id` included: the Lua side turns each
// site into a bindable action keyed by it ("site_<id>"), so a stable id is what
// lets a per-site shortcut survive a rename, a URL edit, and a reorder.
struct SiteRow: Identifiable, Equatable, Codable {
    var id = UUID()
    var name = ""
    var url = ""
    var browser = ""    // bundle id; "" = system default browser
    var profile = ""    // Chrome profile directory; "" = default/current profile
    var app = false
    var incognito = false   // open a fresh private window (Chromium only)

    enum CodingKeys: String, CodingKey { case id, name, url, browser, profile, app, incognito }

    init() {}

    // Tolerant decode: a missing key falls back to the property default rather
    // than failing the whole array (Swift's synthesized Decodable ignores
    // property defaults and would throw on any absent key -- so a hand-edited or
    // partially-written record must not wipe the list).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // No id -- a config written before sites became actions. Keep the freshly
        // generated one, but note that minting it here does NOT persist it: the
        // first real edit does (see the guard in .onChange(of: rows)), and only
        // then does the site's action key change from the URL slug the Lua side
        // falls back to, taking any shortcut bound to that slug with it.
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        browser = try c.decodeIfPresent(String.self, forKey: .browser) ?? ""
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? ""
        app = try c.decodeIfPresent(Bool.self, forKey: .app) ?? false
        incognito = try c.decodeIfPresent(Bool.self, forKey: .incognito) ?? false
    }

    static func encode(_ rows: [SiteRow]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? enc.encode(rows), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// Decode the stored value: a JSON array, or -- for an un-migrated config --
    /// the legacy `Name | URL | app` text (one per line), mirroring the Lua
    /// `parseSite` so existing sites show up as rows.
    static func decode(_ raw: String) -> [SiteRow] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            if let data = trimmed.data(using: .utf8),
               let rows = try? JSONDecoder().decode([SiteRow].self, from: data) {
                return rows
            }
            return []
        }
        return decodeLegacy(trimmed)
    }

    private static func decodeLegacy(_ raw: String) -> [SiteRow] {
        var out: [SiteRow] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var parts = line.split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            if parts.isEmpty { continue }
            var app = false
            if parts.count > 1, parts.last?.lowercased() == "app" { app = true; parts.removeLast() }
            if parts.isEmpty { continue }
            var row = SiteRow()
            if parts.count >= 2 { row.name = parts[0]; row.url = parts[1] } else { row.url = parts[0] }
            row.app = app
            out.append(row)
        }
        return out
    }
}

struct SiteListEditor: View {
    let json: String
    let onChange: (String) -> Void
    /// Re-register the catalog, so an added / removed / renamed site's row appears
    /// in the menubar submenu and the palette. Only the action SET and its LABELS
    /// need this: a site action resolves its site when it fires, so a URL /
    /// browser / profile / app-mode edit takes effect with no reload at all.
    /// Called from `commit()` at the two discrete moments (removing a row,
    /// collapsing an edited one) -- never from `.onChange`, which fires on every
    /// keystroke and would rebind every feature in the app mid-typing.
    let reload: () -> Void

    @State private var rows: [SiteRow] = []
    @State private var expanded: Set<UUID> = []
    @State private var seeded = false
    /// What the last persist wrote (initially: what was decoded). Anything else in
    /// `rows` is a real edit -- see the guard in `.onChange(of: rows)`.
    @State private var persisted: [SiteRow] = []
    /// An edit is stored but the catalog has not re-registered yet, so a site's
    /// menu row / label may still be missing or stale.
    @State private var dirty = false

    // Enumerated once when the editor appears (cheap; reopen Settings to pick up
    // a newly-installed browser / profile).
    private let browsers = BrowserCatalog.installedBrowsers()
    private let profiles = BrowserCatalog.chromeProfiles()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array($rows.enumerated()), id: \.element.id) { index, $row in
                    if index > 0 { Divider() }
                    siteRow($row)
                }
                if rows.isEmpty {
                    Text(Strings.t("sites.empty", default: "No sites yet."))
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            Button {
                let new = SiteRow()
                rows.append(new)
                expanded.insert(new.id)   // a fresh row opens ready to type
            } label: {
                Label(Strings.t("sites.add", default: "Add site"), systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .onAppear {
            if !seeded { rows = SiteRow.decode(json); persisted = rows; seeded = true }
        }
        .onChange(of: json) { new in
            if new.isEmpty && !rows.isEmpty { rows = [] }
        }
        .onChange(of: rows) { new in
            // DECODING IS NOT AN EDIT. For a config written before ids, decode
            // MINTS one per row, so `SiteRow.encode(rows)` already differs from
            // `json` with the user having touched nothing -- and comparing against
            // `json` here meant merely OPENING this page rewrote stored config,
            // flipping every site's action id from its URL slug to the new UUID and
            // silently orphaning any shortcut bound to the slug. So compare against
            // what was last persisted (initially: what was decoded), which a mint
            // equals and a real edit never does.
            guard new != persisted else { return }
            persisted = new
            onChange(SiteRow.encode(new))
            dirty = true
        }
    }

    /// Persist the rows AND re-register, so an added / removed / renamed site's
    /// menu row follows immediately. Persist FIRST -- the reload re-reads the
    /// stored value. Called only from user actions (never from `.onChange`, which
    /// would publish a store change from inside a view update).
    private func commit() {
        persisted = rows
        onChange(SiteRow.encode(rows))
        dirty = false
        reload()
    }

    // MARK: Row

    @ViewBuilder
    private func siteRow(_ row: Binding<SiteRow>) -> some View {
        let site = row.wrappedValue
        let isOpen = expanded.contains(site.id)
        VStack(alignment: .leading, spacing: 8) {
            // Summary line -- a real Button so it's keyboard/VoiceOver actionable
            // (and drivable by AX), not just a tap gesture.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { toggle(site.id) }
            } label: {
                HStack(spacing: 10) {
                    favicon(for: site.url)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(site)).fontWeight(.medium)
                        // Only show the URL subtitle when a name is set, else the
                        // title already IS the domain (no point repeating it).
                        if !site.name.isEmpty, !site.url.isEmpty {
                            Text(displayURL(site.url)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if !isOpen {
                        Text(summary(site)).font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title(site)), \(summary(site))")
            .accessibilityHint(isOpen ? Strings.t("sites.collapse", default: "Collapse")
                                      : Strings.t("sites.expand", default: "Expand to edit"))

            if isOpen { detail(row) }
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func detail(_ row: Binding<SiteRow>) -> some View {
        let isChrome = row.wrappedValue.browser == "com.google.Chrome"
        // "System default" ("") counts as available: the default browser can change
        // between now and the moment the site opens, so the honest answer is not
        // knowable here -- offer it and let the runtime refuse (with a message) if
        // it turns out to be Safari. Never HIDE the toggle: a hidden control with
        // the flag still set is state the user can neither see nor undo.
        let canGoPrivate = row.wrappedValue.browser.isEmpty
            || BrowserCatalog.supportsPrivateWindow(row.wrappedValue.browser)
        // Native grouped-Form rows (title = label): clean macOS settings look,
        // proper alignment, far less layout code than hand-rolled label columns.
        VStack(alignment: .leading, spacing: 7) {
            TextField(Strings.t("sites.name", default: "Name"), text: row.name,
                      prompt: Text(Strings.t("sites.name.ph", default: "optional")))
            TextField(Strings.t("sites.url", default: "URL"), text: row.url, prompt: Text("example.com"))
            // Switching to a browser with no private-window switch clears the flag
            // rather than leaving it set-but-invisible (the toggle below hides
            // itself for such a browser, so the user could not see or undo it).
            Picker(Strings.t("sites.browser", default: "Browser"), selection: Binding(
                get: { row.wrappedValue.browser },
                set: { b in
                    row.browser.wrappedValue = b
                    // Switching to a browser that definitely cannot go private clears
                    // the flag (the toggle below greys out, and a set-but-unreachable
                    // flag would just alert on every open). "System default" is left
                    // alone -- it is unknown, not impossible.
                    if !b.isEmpty && !BrowserCatalog.supportsPrivateWindow(b) {
                        row.incognito.wrappedValue = false
                    }
                })) {
                Text(Strings.t("sites.systemDefault", default: "System default")).tag("")
                ForEach(browsers) { Text($0.name).tag($0.bundleId) }
            }
            if isChrome && !profiles.isEmpty {
                Picker(Strings.t("sites.profile", default: "Profile"), selection: row.profile) {
                    Text(Strings.t("sites.defaultProfile", default: "Default profile")).tag("")
                    ForEach(profiles) { Text($0.name).tag($0.dir) }
                }
            }
            // App mode and private are MUTUALLY EXCLUSIVE, enforced by turning the
            // other off rather than by disabling it: an app window that quietly
            // persisted the visit would be a broken promise, and the seam resolves
            // the pair the same way (private wins). Keeping both clickable means a
            // user is never stuck wondering why a control is greyed.
            Toggle(Strings.t("sites.standalone", default: "Open as a standalone app window"), isOn: Binding(
                get: { row.wrappedValue.app },
                set: { on in
                    row.app.wrappedValue = on
                    if on { row.incognito.wrappedValue = false }
                }))
                .help(Strings.t("sites.standalone.help", default: "Chrome / Chromium only -- a chromeless app-style window. Other browsers open a tab."))
            Toggle(Strings.t("sites.private", default: "Open in a private window"), isOn: Binding(
                get: { row.wrappedValue.incognito },
                set: { on in
                    row.incognito.wrappedValue = on
                    if on { row.app.wrappedValue = false }
                }))
                .disabled(!canGoPrivate)
                .help(canGoPrivate
                      ? Strings.t("sites.private.help", default: "Opens a fresh private window every time -- it never focuses an existing tab, and the visit is never recorded.")
                      : Strings.t("sites.private.unavailable", default: "This browser has no private-window switch a launch can set, so Hammerdeck will not promise one. Chrome and Chromium are supported."))
            HStack {
                Spacer()
                Button(role: .destructive) {
                    let id = row.wrappedValue.id
                    rows.removeAll { $0.id == id }
                    commit()   // drop its menubar row now, not at the next reload
                } label: {
                    Text(Strings.t("sites.remove", default: "Remove site"))
                }
                .controlSize(.small)
            }
        }
        .padding(.top, 2)
    }

    /// Collapsing a row is the "done editing this site" moment, so an edit made in
    /// it commits here -- that is what puts a new site (or a new name) in the
    /// menubar. Collapsing a row nobody edited re-registers nothing.
    private func toggle(_ id: UUID) {
        if expanded.contains(id) {
            expanded.remove(id)
            if dirty { commit() }
        } else {
            expanded.insert(id)
        }
    }

    // MARK: Summary helpers

    private func title(_ site: SiteRow) -> String {
        if !site.name.isEmpty { return site.name }
        if let d = Self.domain(of: site.url) { return d }
        return "New site"
    }

    private func displayURL(_ url: String) -> String {
        Self.domain(of: url) ?? url
    }

    /// The quiet trailing summary on a collapsed row, e.g. "Chrome · peach · App".
    private func summary(_ site: SiteRow) -> String {
        var parts: [String] = []
        if site.browser.isEmpty {
            parts.append("Default")
        } else {
            parts.append(Self.shortName(browsers.first { $0.bundleId == site.browser }?.name ?? site.browser))
        }
        if site.browser == "com.google.Chrome", !site.profile.isEmpty {
            parts.append(profiles.first { $0.dir == site.profile }?.name ?? site.profile)
        }
        if site.app { parts.append("App") }
        if site.incognito { parts.append(Strings.t("sites.private.badge", default: "Private")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Favicon / names

    @ViewBuilder
    private func favicon(for url: String) -> some View {
        if let img = Self.faviconImage(for: url) {
            Image(nsImage: img).resizable().frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 16, height: 16)
        }
    }

    /// "Google Chrome" -> "Chrome", "Brave Browser" -> "Brave".
    private static func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: "Google ", with: "")
            .replacingOccurrences(of: " Browser", with: "")
    }

    /// The cached favicon for a site's domain (shared with the chooser / Tab
    /// Switcher). Path mirrors the Lua side: <Caches>/Hammerdeck/favicons/<domain>.png.
    private static func faviconImage(for url: String) -> NSImage? {
        guard let domain = domain(of: url) else { return nil }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let path = base?
            .appendingPathComponent("Hammerdeck/favicons/\(domain).png").path,
            FileManager.default.fileExists(atPath: path) else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private static func domain(of url: String) -> String? {
        var s = url
        if !s.contains("://") { s = "https://" + s }
        guard let host = URLComponents(string: s)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
