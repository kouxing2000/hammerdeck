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
    case context(FeatureContext)

    var label: String {
        switch self {
        case .all:                return Strings.t("gallery.filter.all", default: "All")
        case .enabled:            return Strings.t("gallery.filter.enabled", default: "Enabled")
        case .disabled:           return Strings.t("gallery.filter.disabled", default: "Disabled")
        case .conflict:           return Strings.t("gallery.filter.conflicts", default: "Conflicts")
        case .context(let c):     return c.title
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
            Text(Strings.t("gallery.title", default: "Feature Gallery")).font(.headline)
            Text(String(format: Strings.t("gallery.enabledCount", default: "%d/%d enabled"), enabledCount, store.features.count))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(Strings.t("gallery.search", default: "Search"), text: $search).textFieldStyle(.plain).frame(width: 150)
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
            .help(Strings.t("gallery.reloadHelp", default: "Reload features from disk -- picks up newly added folders"))
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
                ForEach(contexts, id: \.self) { chip(.context($0)) }
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
                if case .context(let c) = f {
                    Image(systemName: c.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(active ? .white : c.color)
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
                    Text(Strings.t("gallery.noMatch", default: "No features match."))
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(40)
                }
                ForEach(visibleContexts, id: \.self) { context in
                    let cards = visibleFeatures.filter { FeatureContext($0.context) == context }
                    if !cards.isEmpty {
                        HStack(spacing: 7) {
                            Image(systemName: context.icon)
                                .font(.system(size: 12)).foregroundStyle(context.color)
                            Text(context.title)
                                .font(.subheadline.weight(.semibold))
                            Text(context.scenario)
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(cards.count)").font(.caption2).foregroundStyle(.tertiary)
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

    /// The context buckets present in the catalog, in their canonical order.
    private var contexts: [FeatureContext] {
        let present = Set(store.features.map { FeatureContext($0.context) })
        return FeatureContext.allCases.filter { present.contains($0) }
    }

    private var visibleContexts: [FeatureContext] {
        if case .context(let c) = filter { return [c] }
        return contexts
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
        case .context(let c):  return FeatureContext(f.context) == c
        }
    }

    private func matchesSearch(_ f: FeatureInfo) -> Bool {
        guard !search.isEmpty else { return true }
        let q = search.lowercased()
        let ctx = FeatureContext(f.context)
        return f.name.lowercased().contains(q)
            || f.description.lowercased().contains(q)
            || f.category.lowercased().contains(q)
            || ctx.title.lowercased().contains(q)
            || ctx.scenario.lowercased().contains(q)
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
    @State private var hoverStart = Date()   // anchors the playback bar to hover-start

    private var isService: Bool { feature.actions.isEmpty }

    /// The card's primary shortcut glyph: the first action's trigger. Empty for
    /// pure services (shown as "always on" instead).
    private var primaryGlyph: String {
        shortcutGlyph(feature.actions.first?.trigger)
    }

    private var kindBadge: String {
        if isService { return Strings.t("gallery.badge.service", default: "service") }
        if feature.actions.count > 1 {
            return String(format: Strings.t("gallery.badge.shortcuts", default: "%d shortcuts"), feature.actions.count)
        }
        return Strings.t("gallery.badge.action", default: "action")
    }

    private var archetype: FeatureArchetype { FeatureArchetype.of(feature) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            // Archetype preview band: static first frame at rest, animates on
            // hover. Only present for features that have an archetype scene, so
            // the rest of the catalog keeps its compact card (POC: one feature).
            if case .none = archetype {} else {
                ZStack(alignment: .bottom) {
                    archetype.scene(playing: hover && !feature.failed)
                        .frame(height: 78)
                        .frame(maxWidth: .infinity)
                    // Playback progress: while hovering, a thin bar sweeps over the
                    // scene's loop duration (anchored at hover-start, same as the
                    // scene), so reaching the end means the loop just replayed.
                    if hover && !feature.failed {
                        playbackBar(loop: archetype.loopDuration)
                            .transition(.opacity)
                    }
                }
                // A play affordance over the calm first frame teaches that the
                // preview animates -- otherwise the static frame gives no hint to
                // hover. It fades out on hover, where the motion (and the progress
                // bar) speak for themselves. It's a hint, not a button: clicking
                // opens Settings like the rest of the card (hover is the trigger).
                .overlay(alignment: .center) {
                    if !hover && !feature.failed { playHint }
                }
                .animation(.easeInOut(duration: 0.18), value: hover)
            }
            Text(feature.name).font(.headline).lineLimit(1)
            Text(feature.failed
                 ? (feature.errorMessage.isEmpty ? Strings.t("gallery.failedToLoad", default: "Failed to load.") : feature.errorMessage)
                 : (feature.description.isEmpty ? Strings.t("gallery.noDescription", default: "No description.") : feature.description))
                .font(.caption)
                .foregroundStyle(feature.failed ? .red : .secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            if !unmetRequirements.isEmpty && !feature.failed {
                requirementBadges
            }
            Divider()
            footer
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(cardStroke, lineWidth: feature.failed ? 1.2 : 1))
        .shadow(color: .black.opacity(hover && !feature.failed ? 0.12 : 0), radius: 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { onOpen() }
        .onHover { hovering in
            if hovering { hoverStart = Date() }   // restart the loop clock on entry
            hover = hovering
        }
        .help(feature.failed
              ? Strings.t("gallery.brokenHelp", default: "Broken plugin -- click for details")
              : String(format: Strings.t("gallery.configureHelp", default: "Click to configure %@"), feature.name))
    }

    /// Playback progress for the preview loop: a thin bar that sweeps left-to-right
    /// over `loop` seconds, anchored at hover-start (so it tracks the scene), then
    /// snaps back -- the snap is the "finished, replaying" cue. Driven by a
    /// TimelineView so it's smooth and stops when the card un-hovers (view removed).
    private func playbackBar(loop: Double) -> some View {
        TimelineView(.animation) { ctx in
            let elapsed = ctx.date.timeIntervalSince(hoverStart)
            let p = loop > 0 ? CGFloat((elapsed.truncatingRemainder(dividingBy: loop)) / loop) : 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.25)).frame(height: 3)
                    Capsule().fill(Color.accentColor).frame(width: geo.size.width * p, height: 3)
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .allowsHitTesting(false)
    }

    /// The "this previews on hover" affordance: a play glyph over the calm frame.
    /// Non-interactive (allowsHitTesting false) so taps fall through to the card.
    private var playHint: some View {
        Image(systemName: "play.circle.fill")
            .font(.system(size: 24))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.4))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .transition(.opacity)
            .allowsHitTesting(false)
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
            if feature.recommended && !feature.failed {
                Image(systemName: "star.fill")
                    .font(.caption2).foregroundStyle(.yellow)
                    .help(Strings.t("gallery.recommendedHelp", default: "Recommended -- part of the Essentials starter set"))
            }
            if conflicted && !feature.failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help(Strings.t("gallery.conflictHelp", default: "Shortcut conflict -- see the Shortcut Map"))
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
                Label(Strings.t("gallery.alwaysOn", default: "always on"), systemImage: "infinity")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if primaryGlyph.isEmpty {
                Text(Strings.t("gallery.noShortcut", default: "no shortcut")).font(.caption2).foregroundStyle(.tertiary)
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
                set: { store.requestSetEnabled(feature.id, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(feature.failed)
        }
    }

    /// Preconditions the user hasn't satisfied yet. A granted permission drops
    /// off the list (no nagging once it's met).
    private var unmetRequirements: [String] {
        feature.requires.filter { req in
            switch req {
            case "accessibility": return !store.axTrusted
            default:              return true
            }
        }
    }

    /// Precondition pills that are also the FIX: tapping fires the system grant
    /// prompt, so "Needs Accessibility" isn't a dead sign -- it's the door. Closes
    /// the "I added it but nothing happens" trap on the silently-no-op features.
    private var requirementBadges: some View {
        HStack(spacing: 6) {
            ForEach(unmetRequirements, id: \.self) { r in
                Button { store.promptAccessibility() } label: {
                    Label(String(format: Strings.t("gallery.grant", default: "%@ — Grant"), requirementLabel(r)), systemImage: "lock.shield")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.16)))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help(Strings.t("gallery.grantHelp", default: "Open System Settings to grant Accessibility, then it works"))
            }
            Spacer(minLength: 0)
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
