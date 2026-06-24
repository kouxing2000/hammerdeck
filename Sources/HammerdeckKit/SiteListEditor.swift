// The editor for a `siteList` option (Quick Sites). Renders the configured
// sites as an expandable list: each row is a calm one-line summary (favicon,
// name, URL, a quiet browser/profile/app summary) that expands inline into a
// full-width labeled form. Replaces the old `Name | URL | app` text box.
// Persisted as a JSON array of SiteRow; legacy text configs decode into rows on
// first open (one-time migration on next edit).

import SwiftUI

// One configured site. Stored as JSON; `id` is editor-only (excluded from the
// CodingKeys so it never reaches the JSON or the Lua side).
struct SiteRow: Identifiable, Equatable, Codable {
    var id = UUID()
    var name = ""
    var url = ""
    var browser = ""    // bundle id; "" = system default browser
    var profile = ""    // Chrome profile directory; "" = default/current profile
    var app = false

    enum CodingKeys: String, CodingKey { case name, url, browser, profile, app }

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

    @State private var rows: [SiteRow] = []
    @State private var expanded: Set<UUID> = []
    @State private var seeded = false

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
                    Text("No sites yet.")
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
                Label("Add site", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .onAppear { if !seeded { rows = SiteRow.decode(json); seeded = true } }
        .onChange(of: json) { new in
            if new.isEmpty && !rows.isEmpty { rows = [] }
        }
        .onChange(of: rows) { new in
            let encoded = SiteRow.encode(new)
            if encoded != json { onChange(encoded) }
        }
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
            .accessibilityHint(isOpen ? "Collapse" : "Expand to edit")

            if isOpen { detail(row) }
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func detail(_ row: Binding<SiteRow>) -> some View {
        let isChrome = row.wrappedValue.browser == "com.google.Chrome"
        // Native grouped-Form rows (title = label): clean macOS settings look,
        // proper alignment, far less layout code than hand-rolled label columns.
        VStack(alignment: .leading, spacing: 7) {
            TextField("Name", text: row.name, prompt: Text("optional"))
            TextField("URL", text: row.url, prompt: Text("example.com"))
            Picker("Browser", selection: row.browser) {
                Text("System default").tag("")
                ForEach(browsers) { Text($0.name).tag($0.bundleId) }
            }
            if isChrome && !profiles.isEmpty {
                Picker("Profile", selection: row.profile) {
                    Text("Default profile").tag("")
                    ForEach(profiles) { Text($0.name).tag($0.dir) }
                }
            }
            Toggle("Open as a standalone app window", isOn: row.app)
                .help("Chrome / Chromium only -- a chromeless app-style window. Other browsers open a tab.")
            HStack {
                Spacer()
                Button(role: .destructive) {
                    let id = row.wrappedValue.id
                    rows.removeAll { $0.id == id }
                } label: {
                    Text("Remove site")
                }
                .controlSize(.small)
            }
        }
        .padding(.top, 2)
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
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
