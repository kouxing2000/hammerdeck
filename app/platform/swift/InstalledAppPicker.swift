// The searchable app list shared by the rules editor's app-target chooser
// (`AppTargetChooser` in RulesView) and the App Launcher alias editor
// (`AliasListEditor`). The rules-only chrome -- the "app from the trigger"
// sentinel row and the warning/hint line -- stays with AppTargetChooser, which
// composes this.
//
// Empty query shows the RUNNING apps as quick options (the common target);
// typing searches ALL installed apps, so an app that isn't running is still
// pickable. Both sets come from AppCatalog, whose installed list is a plain
// directory scan -- deliberately not Spotlight, which answers nothing when
// indexing is off.

import AppKit
import SwiftUI

struct InstalledAppPicker: View {
    /// The chosen app, drawn with a trailing check. "" when nothing is chosen.
    let selectedBundleId: String
    /// The picked app. The caller decides what to store (a bundle id, a name, both).
    let onPick: (_ name: String, _ bundleId: String) -> Void
    /// Offered when the query matches nothing, letting a caller that can live with
    /// a name-only target accept the typed text (the rules engine matches an app by
    /// name when it has no id). Absent by default: a caller that NEEDS a resolvable
    /// bundle id must not be handed one it cannot use.
    var onUseTypedName: ((String) -> Void)?

    @State private var installed: [(name: String, bundleId: String)] = []
    @State private var running: [(name: String, bundleId: String)] = []
    @State private var query = ""
    @State private var loaded = false   // installed list finished gathering

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var searching: Bool { !trimmed.isEmpty }
    // Empty search -> running apps (quick); typing -> all installed, filtered.
    private var rows: [(name: String, bundleId: String)] {
        searching ? installed.filter { $0.name.localizedCaseInsensitiveContains(trimmed) } : running
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(Strings.t("apps.search", default: "Search apps"), text: $query)
                .textFieldStyle(.roundedBorder)

            if searching && !loaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(Strings.t("apps.loading", default: "Finding apps…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if rows.isEmpty {
                // Searching with no match -> offer the typed text as a literal name,
                // when the caller accepts one. Empty with nothing running -> nudge
                // to search.
                if searching, let useTyped = onUseTypedName {
                    Button { useTyped(trimmed) } label: {
                        Text(String(format: Strings.t("apps.useTyped", default: "Use \u{201C}%@\u{201D} as a name"), trimmed))
                            .font(.caption)
                    }.buttonStyle(.plain)
                } else if searching {
                    Text(Strings.t("apps.noMatch", default: "No installed app matches that."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(Strings.t("apps.typeToSearch", default: "Type to search all installed apps."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if !searching {
                    Text(Strings.t("apps.runningHeader", default: "Running -- type to search all installed"))
                        .font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
                }
                ScrollView {
                    // Lazy so a long installed-search list only resolves icons for the
                    // rows actually on screen.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.bundleId) { app in
                            appRow(app, selected: selectedBundleId == app.bundleId) {
                                onPick(app.name, app.bundleId)
                                query = ""
                            }
                        }
                    }
                }
                // A ScrollView in a popover has NO intrinsic height -- with only a
                // maxHeight it collapses to zero and the rows vanish (the bug that hid
                // the running apps). Pin a definite height: fit the content, capped so
                // a long installed-search list scrolls.
                .frame(height: min(CGFloat(rows.count) * 28 + 4, 240))
            }
        }
        .task {
            running = AppCatalog.runningApps()       // instant -- the quick options
            installed = AppCatalog.installedApps()
            loaded = true
        }
    }

    // An app row: the app's icon, its name, and a trailing check when chosen.
    @ViewBuilder private func appRow(_ app: (name: String, bundleId: String),
                                     selected: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 8) {
                if let icon = AppCatalog.icon(forBundleId: app.bundleId) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "app").frame(width: 16, height: 16).foregroundStyle(.secondary)
                }
                Text(app.name).foregroundStyle(.primary)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}
