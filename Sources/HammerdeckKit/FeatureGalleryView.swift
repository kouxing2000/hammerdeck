import SwiftUI
import AppKit

// The Feature Gallery: the DISCOVERY surface. The Settings sidebar is fine for
// configuring a feature you already know; the Gallery answers "what do I have,
// what am I not using, what's that feature again?" -- a storefront-style card
// grid over the whole catalog, grouped by category, enable in place.
//
// Pure presentation over registry.describe() + setEnabled (no new model, no
// native, no seam change). It is the BROWSE layer; clicking a card body opens
// the existing Settings detail (the CONFIGURE layer) for that feature, so the
// generated options form stays the one place a feature is configured.

private enum GalleryFilter: Hashable {
    case all, enabled, disabled, conflict
    case category(String)

    var label: String {
        switch self {
        case .all:                return "All"
        case .enabled:            return "Enabled"
        case .disabled:           return "Disabled"
        case .conflict:           return "Conflicts"
        case .category(let c):    return c.capitalized
        }
    }
}

struct FeatureGalleryView: View {
    @ObservedObject var store: SettingsStore

    /// Opens the Settings window focused on a feature (set by the host in Boot).
    let openSettings: (String) -> Void

    @State private var search = ""
    @State private var filter: GalleryFilter = .all
    @State private var conflicts: Set<String> = []

    private let columns = [GridItem(.adaptive(minimum: 248, maximum: 360), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            filterBar
            Divider()
            grid
        }
        // Embedded in the Homepage shell, which owns the window minimum size.
        .onAppear {
            store.refresh()
            recomputeConflicts()
        }
        // Recompute the conflict set (Lua evals) only when the catalog actually
        // changes -- not on every render.
        .task(id: catalogSignature) { recomputeConflicts() }
    }

    // MARK: chrome

    private var toolbar: some View {
        HStack {
            Text("Feature Gallery").font(.headline)
            Text("\(enabledCount)/\(store.features.count) enabled")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain).frame(width: 150)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            Button {
                store.reload()
                recomputeConflicts()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload features from disk -- picks up newly added folders")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(.all)
                chip(.enabled)
                chip(.disabled)
                if !conflicts.isEmpty { chip(.conflict) }
                Divider().frame(height: 16)
                ForEach(categories, id: \.self) { chip(.category($0)) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func chip(_ f: GalleryFilter) -> some View {
        let active = filter == f
        return Button {
            filter = f
        } label: {
            HStack(spacing: 4) {
                if case .category(let c) = f {
                    Circle().fill(categoryColor(c)).frame(width: 7, height: 7)
                } else if case .conflict = f {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9)).foregroundStyle(active ? .white : .orange)
                }
                Text(f.label).font(.caption.weight(active ? .semibold : .regular))
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(active ? Color.accentColor : Color.gray.opacity(0.14)))
            .foregroundStyle(active ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if visibleFeatures.isEmpty {
                    Text("No features match.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(40)
                }
                ForEach(visibleCategories, id: \.self) { category in
                    let cards = visibleFeatures.filter { $0.category == category }
                    if !cards.isEmpty {
                        HStack(spacing: 6) {
                            Circle().fill(categoryColor(category)).frame(width: 8, height: 8)
                            Text(category.capitalized)
                                .font(.subheadline.weight(.semibold))
                            Text("\(cards.count)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(cards) { feature in
                                FeatureCard(store: store, feature: feature,
                                            conflicted: conflicts.contains(feature.id),
                                            onOpen: { openSettings(feature.id) })
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: data

    private var enabledCount: Int { store.features.filter { $0.enabled }.count }

    private var categories: [String] {
        var seen: [String] = []
        for f in store.features where !seen.contains(f.category) { seen.append(f.category) }
        return seen
    }

    private var visibleCategories: [String] {
        if case .category(let c) = filter { return [c] }
        return categories
    }

    private var visibleFeatures: [FeatureInfo] {
        store.features.filter { f in
            matchesFilter(f) && matchesSearch(f)
        }
    }

    private func matchesFilter(_ f: FeatureInfo) -> Bool {
        switch filter {
        case .all:             return true
        case .enabled:         return f.enabled
        case .disabled:        return !f.enabled
        case .conflict:        return conflicts.contains(f.id)
        case .category(let c): return f.category == c
        }
    }

    private func matchesSearch(_ f: FeatureInfo) -> Bool {
        guard !search.isEmpty else { return true }
        let q = search.lowercased()
        return f.name.lowercased().contains(q)
            || f.description.lowercased().contains(q)
            || f.category.lowercased().contains(q)
    }

    /// Changes whenever a feature's id/enabled/trigger set changes -- the inputs
    /// to the conflict scan. Keying .task on this avoids re-evaling Lua per render.
    private var catalogSignature: String {
        store.features.map { f in
            "\(f.id):\(f.enabled):" + f.actions.map { $0.triggerDesc }.joined(separator: ",")
        }.joined(separator: "|")
    }

    private func recomputeConflicts() {
        conflicts = store.conflictedFeatureIds()
        // If the active filter just emptied out (last conflict resolved), fall
        // back to All so the user isn't staring at a blank grid.
        if case .conflict = filter, conflicts.isEmpty { filter = .all }
    }
}

// MARK: - One feature card

private struct FeatureCard: View {
    @ObservedObject var store: SettingsStore
    let feature: FeatureInfo
    let conflicted: Bool
    let onOpen: () -> Void

    @State private var hover = false

    private var isService: Bool { feature.actions.isEmpty }

    /// The card's primary shortcut glyph: the first action's trigger. Empty for
    /// pure services (shown as "always on" instead).
    private var primaryGlyph: String {
        shortcutGlyph(feature.actions.first?.trigger)
    }

    private var kindBadge: String {
        if isService { return "service" }
        if feature.actions.count > 1 { return "\(feature.actions.count) shortcuts" }
        return "action"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(feature.name).font(.headline).lineLimit(1)
            Text(feature.failed
                 ? (feature.errorMessage.isEmpty ? "Failed to load." : feature.errorMessage)
                 : (feature.description.isEmpty ? "No description." : feature.description))
                .font(.caption)
                .foregroundStyle(feature.failed ? .red : .secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            Divider()
            footer
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(cardStroke, lineWidth: feature.failed ? 1.2 : 1))
        .shadow(color: .black.opacity(hover && !feature.failed ? 0.12 : 0), radius: 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { onOpen() }
        .onHover { hover = $0 }
        .help(feature.failed
              ? "Broken plugin -- click for details"
              : "Click to configure \(feature.name)")
    }

    private var header: some View {
        HStack {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(categoryColor(feature.category).opacity(feature.failed ? 0.15 : 0.22))
                    .frame(width: 30, height: 30)
                Image(systemName: feature.failed ? "exclamationmark.triangle.fill"
                                                  : categoryIcon(feature.category))
                    .foregroundStyle(feature.failed ? Color.red : categoryColor(feature.category))
            }
            Spacer()
            if conflicted && !feature.failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help("Shortcut conflict -- see the Shortcut Map")
            }
            Text(kindBadge)
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if isService {
                Label("always on", systemImage: "infinity")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if primaryGlyph.isEmpty {
                Text("no shortcut").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text(primaryGlyph)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.14)))
            }
            Spacer()
            // A never-registered (failed) module can't be toggled.
            Toggle("", isOn: Binding(
                get: { feature.enabled },
                set: { store.setEnabled(feature.id, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(feature.failed)
        }
    }

    private var cardFill: Color {
        if feature.failed { return Color.red.opacity(0.06) }
        return feature.enabled ? Color.accentColor.opacity(0.06) : Color.gray.opacity(0.05)
    }

    private var cardStroke: Color {
        if feature.failed { return Color.red.opacity(0.5) }
        if hover { return Color.accentColor.opacity(0.6) }
        return feature.enabled ? Color.accentColor.opacity(0.35) : .secondary.opacity(0.18)
    }
}
