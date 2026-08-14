// The editor for an `aliasList` option (App Launcher's search aliases). Each row
// pairs an installed app with the short names you want to be able to type for it
// -- "vsc" for Visual Studio Code, "finder" for 访达 on a Chinese-locale Mac,
// where the app's display name is the one thing an English search misses.
//
// The app is PICKED, never typed, and stored by BUNDLE ID: an alias table keyed
// by display name would break on a system-language switch or an app rename, which
// is the same class of breakage the aliases exist to fix. Persisted as a JSON
// array of AliasRow in the option's own namespace.
//
// Unlike SiteListEditor / PlacementListEditor there is no `reload` here: an alias
// creates no action and changes no label, so nothing needs re-registering -- the
// feature re-reads the option every time the launcher opens.

import AppKit
import SwiftUI

/// One app's aliases. `id` is view identity only and is deliberately NOT
/// persisted (nothing keys off it -- contrast SiteRow, whose id names an action);
/// the bundle id is the record's real identity.
struct AliasRow: Identifiable, Equatable, Codable {
    var id = UUID()
    var bundleId = ""
    var aliases: [String] = []

    enum CodingKeys: String, CodingKey { case bundleId, aliases }

    init() {}

    // Tolerant decode: a missing key falls back to the property default rather than
    // failing the whole array, so one hand-edited or partially-written record can't
    // wipe the list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId) ?? ""
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }

    static func encode(_ rows: [AliasRow]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? enc.encode(rows), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// One element that fails to decode is SKIPPED, never fatal to the array. A
    /// whole-array `try?` would turn a single wrong-typed field into "No aliases
    /// yet", and the next edit would then persist that emptiness over every
    /// surviving record. The Lua reader (`aliasIndex`) tolerates a bad row the same
    /// way, so both readers of this blob keep one contract.
    static func decode(_ raw: String) -> [AliasRow] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
              let rows = try? JSONDecoder().decode([LenientRow].self, from: data) else { return [] }
        return rows.compactMap(\.row)
    }
}

/// Decodes an AliasRow, or nothing at all -- the per-element tolerance behind
/// `AliasRow.decode`.
private struct LenientRow: Decodable {
    let row: AliasRow?
    init(from decoder: Decoder) throws { row = try? AliasRow(from: decoder) }
}

struct AliasListEditor: View {
    let json: String
    let onChange: (String) -> Void

    @State private var rows: [AliasRow] = []
    @State private var seeded = false
    /// What the last persist wrote (initially: what was decoded). Anything else in
    /// `rows` is a real edit -- see the guard in `.onChange(of: rows)`. Without it
    /// the `onAppear` seed writes on open, marking the option customized when the
    /// user has touched nothing.
    @State private var persisted: [AliasRow] = []
    /// The row whose app picker is open; `addingRow` is the picker on the Add
    /// button, which has no row yet.
    @State private var picking: UUID?
    @State private var addingRow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach($rows) { $row in
                if row.id != rows.first?.id { Divider() }
                AliasTagRow(
                    row: $row,
                    picking: Binding(get: { picking == row.id },
                                     set: { picking = $0 ? row.id : nil }),
                    onRemove: { [id = row.id] in
                        rows.removeAll { $0.id == id }
                        if picking == id { picking = nil }
                    })
            }
            if rows.isEmpty {
                Text(Strings.t("alias.empty", default: "No aliases yet."))
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
        .onAppear {
            if !seeded { rows = AliasRow.decode(json); persisted = rows; seeded = true }
        }
        .onChange(of: json) { new in
            if new.isEmpty && !rows.isEmpty { rows = [] }
        }
        .onChange(of: rows) { new in
            guard new != persisted else { return }   // decoding is not an edit
            persisted = new
            onChange(AliasRow.encode(new))
        }
    }

    // MARK: Add

    /// The last row of the list, INSIDE the box -- a borderless control floating
    /// under it reads as a caption, not an action (SiteListEditor's note). Padding
    /// sits inside the label so the whole row height is the hit target.
    ///
    /// The picker hangs off THIS button, and a row is appended only once an app is
    /// chosen. Appending an empty row first and presenting against it cannot work:
    /// the anchor is not in the hierarchy yet when the flag flips. It would also
    /// leave a blank record behind whenever the picker is dismissed.
    private var addRow: some View {
        Button { addingRow = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill").frame(width: 16, height: 16)
                Text(Strings.t("alias.add", default: "Add alias")).fontWeight(.medium)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tint)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $addingRow) {
            InstalledAppPicker(selectedBundleId: "", onPick: { _, pickedId in
                addingRow = false
                // Choosing an app that already has a row edits that row rather than
                // starting a rival one: two rows for one app would both apply, with
                // nothing on screen saying which.
                if !rows.contains(where: { $0.bundleId == pickedId }) {
                    var new = AliasRow()
                    new.bundleId = pickedId
                    rows.append(new)
                }
            })
            .frame(width: 300)
            .padding(12)
        }
    }
}

/// One app and its alias tags. Its transient editing state -- the half-typed alias
/// and the keyboard focus -- lives HERE rather than in dictionaries on the parent
/// (the shape PlacementSnapRow uses): ForEach identity already gives each row its
/// own copy, and keeping it local means a keystroke rebuilds this row instead of
/// every row in the list.
private struct AliasTagRow: View {
    @Binding var row: AliasRow
    @Binding var picking: Bool
    let onRemove: () -> Void

    /// The half-typed alias, before Return turns it into a tag. Nothing splits text
    /// on a separator: an alias is whatever you typed, so a comma or a space inside
    /// one is simply part of it.
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                appButton
                Spacer(minLength: 8)
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Strings.t("alias.remove", default: "Remove this app's aliases"))
            }
            tagBox
        }
        .padding(.vertical, 8)
        // Focus leaving the field commits what is in it. Without this, typing an
        // alias and clicking away discards it -- and the field goes on DISPLAYING
        // the text, so it looks saved until Settings is reopened and it is gone.
        .onChange(of: focused) { now in if !now { commit() } }
    }

    /// The tags and the entry cursor in ONE box, on their own full-width line.
    ///
    /// It sits under the app rather than beside it because a Settings row must not
    /// impose a hard minimum width: side by side, the tags could only overflow, and
    /// the detail pane widened the window until the sidebar went off screen. Here
    /// they WRAP instead, so the row grows a line rather than the window a column.
    private var tagBox: some View {
        FlowLayout(hSpacing: 5, vSpacing: 5) {
            // Indexed, not `id: \.self`: two equal aliases are possible in a
            // hand-edited value, and identical identities would render as one row
            // and delete together.
            ForEach(Array(row.aliases.enumerated()), id: \.offset) { i, alias in
                tag(alias) { row.aliases.remove(at: i) }
            }
            // `prompt:` + `.labelsHidden()`, never `TextField("add a short name",
            // text:)`. Inside a Form -- which is what a Settings option row is --
            // macOS promotes a TextField's title to a LABEL beside the control, so
            // that spelling renders the hint as wrapped text next to an unexplained
            // empty box instead of as placeholder text inside it.
            TextField("", text: $draft,
                      prompt: Text(Strings.t("alias.placeholder", default: "add a short name")))
                .labelsHidden()
                .textFieldStyle(.plain)      // the BOX is the border; a second one nests
                .font(.callout)              // same size as a tag, like a token field
                // A definite width, because FlowLayout sizes every subview by its
                // IDEAL size and a TextField's ideal width is not a number you can
                // predict. 120 is under any pane width, so it wraps to its own line
                // rather than ever widening the window.
                .frame(width: 120)
                .focused($focused)
                .onSubmit(commit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        // The whole box is the hit target, like a real token field -- clicking the
        // empty space to the right of the last tag must land in the field.
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    /// Trim, drop empties, and refuse a case-insensitive duplicate. A REFUSED
    /// duplicate keeps the text in the field: clearing it looks exactly like a
    /// successful commit, so the user would believe an alias was added that wasn't.
    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        guard !row.aliases.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame })
        else { return }
        row.aliases.append(text)
        draft = ""
    }

    private func tag(_ alias: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            // Bounded, because `lineLimit(1)` forbids WRAPPING, not WIDTH: an
            // unbounded Text reports its whole string as its ideal width, FlowLayout
            // reports the widest row, and one pasted 60-character alias would become
            // a hard minimum that widens the pane -- the regression this layout
            // exists to prevent. The stored alias keeps its full text.
            Text(alias).font(.callout).lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(Strings.t("alias.removeTag", default: "Remove this alias"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    /// The app cell: icon + name, opening the shared installed-app picker to CHANGE
    /// which app these aliases belong to. An id that no longer resolves keeps its raw
    /// bundle id on screen and says so -- silently blanking the row would hide an
    /// alias that has stopped working.
    private var appButton: some View {
        let resolved = AppCatalog.displayName(forBundleId: row.bundleId)
        return Button { picking.toggle() } label: {
            HStack(spacing: 8) {
                if let icon = AppCatalog.icon(forBundleId: row.bundleId) {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "app.dashed").frame(width: 18, height: 18)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(resolved ?? row.bundleId)
                        .foregroundStyle(resolved != nil ? .primary : .secondary)
                        .lineLimit(1)
                    if resolved == nil {
                        Text(Strings.t("alias.notInstalled", default: "Not installed"))
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Content-sized, with no frame: a width here becomes the row's hard minimum,
        // which the Settings detail pane must satisfy by widening the window.
        .popover(isPresented: $picking) {
            // No `onUseTypedName`: an alias needs a real bundle id to launch, so a
            // name the scan can't resolve must not be storable here.
            InstalledAppPicker(selectedBundleId: row.bundleId,
                               onPick: { _, pickedId in
                                   row.bundleId = pickedId
                                   picking = false
                               })
            .frame(width: 300)
            .padding(12)
        }
    }
}
