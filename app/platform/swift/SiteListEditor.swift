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
            // Per-element, so one wrong-typed field costs that site and not the
            // list -- see LenientDecode.swift. `nil` here means the text opened
            // with "[" but is not a decodable array at all; there is no legacy
            // config in that shape, so it yields no sites.
            return [SiteRow].decodeLeniently(fromJSON: trimmed) ?? []
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
    /// Private rows whose URL is showing right now. Reset when the row collapses,
    /// so a private site's address is never on screen at a glance -- only while
    /// its editor is open AND the user asked for it.
    @State private var revealed: Set<UUID> = []
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
                Divider()
                addRow
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
        // Decoding is NOT an edit here in the sharpest way of the three editors:
        // decode MINTS an id for a config written before sites became actions, so
        // the re-encoded text differs from `json` with the user having touched
        // nothing. Comparing text would rewrite stored config on open, flipping
        // every site's action id and orphaning shortcuts bound to the old one --
        // which is why the shared modifier compares decoded ROWS.
        .rowListPersistence(json: json, rows: $rows,
                            decode: SiteRow.decode, encode: SiteRow.encode,
                            write: onChange, onEdit: { dirty = true })
    }

    /// Persist the rows AND re-register, so an added / removed / renamed site's
    /// menu row follows immediately. Writes explicitly rather than leaving it to
    /// the persistence hook: that hook runs after the view update, which is too
    /// late to order `reload()` against, and the reload re-reads the stored value.
    /// Called only from user actions (never from `.onChange`, which would publish a
    /// store change from inside a view update).
    private func commit() {
        onChange(SiteRow.encode(rows))
        dirty = false
        reload()
    }

    // MARK: Add

    /// The last row of the list, inside the box. Two constraints, both easy to
    /// undo by accident: it must not become a borderless control floating UNDER
    /// the box -- there it reads as a caption, same grey and weight as the help
    /// text right beneath it, rather than an action -- and the padding must stay
    /// INSIDE the label so the whole row height is the hit target, not just the
    /// text. The icon takes the favicon column's width so it lines up with the
    /// sites above.
    private var addRow: some View {
        Button {
            let new = SiteRow()
            rows.append(new)
            expanded.insert(new.id)   // a fresh row opens ready to type
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill").frame(width: 16, height: 16)
                Text(Strings.t("sites.add", default: "Add site")).fontWeight(.medium)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tint)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    siteIcon(for: site)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(site)).fontWeight(.medium)
                        // Only show the URL subtitle when a name is set, else the
                        // title already IS the domain (no point repeating it). A
                        // private site shows no address here at all -- open the row
                        // and reveal it.
                        if !site.name.isEmpty, !site.url.isEmpty, !site.incognito {
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
            urlField(row)
            // Switching to a browser with no private-window switch clears the flag
            // rather than leaving it set-but-invisible (the toggle below hides
            // itself for such a browser, so the user could not see or undo it).
            Picker(Strings.t("sites.browser", default: "Browser"), selection: Binding(
                get: { row.wrappedValue.browser },
                set: { b in
                    row.browser.wrappedValue = b
                    // Switching to a browser that definitely cannot go private clears
                    // the flag: the toggle below greys out, and a set-but-unreachable
                    // flag would just alert on every open. "System default" is left
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
            // App mode and private COMBINE (measured -- see the seam's note): both
            // on gives a chromeless window that is also private. They were briefly
            // forced apart here on the assumption that Chrome would not honor the
            // pair, which cost a real combination for no gain.
            Toggle(Strings.t("sites.standalone", default: "Open as a standalone app window"), isOn: row.app)
                .help(Strings.t("sites.standalone.help", default: "Chrome / Chromium only -- a chromeless app-style window. Other browsers open a tab."))
            Toggle(Strings.t("sites.private", default: "Open in a private window"), isOn: Binding(
                get: { row.wrappedValue.incognito },
                set: { on in
                    row.incognito.wrappedValue = on
                    // Turning it on mid-edit must not blank the URL the user is
                    // typing -- they are looking at their own screen on purpose.
                    // Collapsing the row is what re-hides it.
                    if on { revealed.insert(row.wrappedValue.id) }
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
                    expanded.remove(id)
                    revealed.remove(id)
                    commit()   // drop its menubar row now, not at the next reload
                } label: {
                    Text(Strings.t("sites.remove", default: "Remove site"))
                }
                .controlSize(.small)
            }
        }
        .padding(.top, 2)
    }

    /// The URL row. A private site's address is masked and comes back on the eye
    /// button: the point of marking a site private is that nobody glancing at the
    /// screen learns where it goes, and a Settings list that prints it defeats that
    /// as surely as the picker would.
    ///
    /// The masked state is inert TEXT, never a `SecureField`. A secure field turns
    /// on macOS SECURE EVENT INPUT while it holds focus, and that mutes every
    /// session event tap in the process -- including this app's own Caps->Hyper tap
    /// (`CapsHyperTap`, `.cgSessionEventTap`). Masking a URL must not switch off a
    /// global hotkey. It also keeps one view identity across the toggle, so
    /// revealing mid-edit does not tear the field down and drop first responder.
    @ViewBuilder
    private func urlField(_ row: Binding<SiteRow>) -> some View {
        let id = row.wrappedValue.id
        let masked = row.wrappedValue.incognito && !revealed.contains(id)
        let label = Strings.t("sites.url", default: "URL")
        HStack(spacing: 6) {
            if masked {
                LabeledContent(label) {
                    Text(String(repeating: "•", count: min(row.wrappedValue.url.count, 16)))
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField(label, text: row.url, prompt: Text(verbatim: "example.com"))
            }
            if row.wrappedValue.incognito {
                Button {
                    if revealed.contains(id) { revealed.remove(id) } else { revealed.insert(id) }
                } label: {
                    Image(systemName: masked ? "eye" : "eye.slash")
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(masked ? Strings.t("sites.url.show", default: "Show the address")
                             : Strings.t("sites.url.hide", default: "Hide the address"))
            }
        }
    }

    /// Collapsing a row is the "done editing this site" moment, so an edit made in
    /// it commits here -- that is what puts a new site (or a new name) in the
    /// menubar. Collapsing a row nobody edited re-registers nothing.
    private func toggle(_ id: UUID) {
        if expanded.contains(id) {
            expanded.remove(id)
            revealed.remove(id)   // a closed private row is hidden again
            if dirty { commit() }
        } else {
            expanded.insert(id)
        }
    }

    // MARK: Summary helpers

    /// An unnamed site is titled by its domain -- except a private one, where that
    /// fallback would print the very address the row hides. Such a row reads
    /// "Private site" until the user names it: two of them are told apart by
    /// naming them, which is the only discreet identity a site can have.
    private func title(_ site: SiteRow) -> String {
        if !site.name.isEmpty { return site.name }
        if site.incognito, !site.url.isEmpty {
            return Strings.t("sites.unnamedPrivate", default: "Private site")
        }
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
        // Both badges can appear on one row now that app mode and private compose,
        // so "App" goes through Strings too -- a hardcoded literal next to a
        // translated one reads as "Chrome · App · 隐私".
        if site.app { parts.append(Strings.t("sites.app.badge", default: "App")) }
        if site.incognito { parts.append(Strings.t("sites.private.badge", default: "Private")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Favicon / names

    /// A private site gets the generic incognito glyph, never its real favicon --
    /// the icon names the destination as plainly as the URL does. Its favicon is
    /// also never fetched (see the picker), so there is usually nothing cached to
    /// draw; the branch is on the flag rather than on the cache because the shared
    /// favicon dir may already hold that domain from an ordinary browsing session.
    @ViewBuilder
    private func siteIcon(for site: SiteRow) -> some View {
        if site.incognito {
            Image(systemName: "eyeglasses").foregroundStyle(.secondary).frame(width: 16, height: 16)
        } else {
            favicon(for: site.url)
        }
    }

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
