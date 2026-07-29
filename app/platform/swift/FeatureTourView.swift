import SwiftUI

// The Feature Tour: the first-run ONBOARDING surface. A new user starts with a
// blank deck (nothing enabled -- see lua/hammerdeck.lua) and meets the catalog
// one feature at a time here: a LARGE, auto-playing preview of what the feature
// actually does, with a single "Add" to enable it. The point is "see it, decide
// fast, add it" -- the opposite of dumping all 19 features on a new user.
//
// Pure presentation, like the Gallery: it reuses the SAME archetype scenes
// (FeatureArchetype.scene) the Gallery card plays on hover, only bigger and
// always-playing, and toggles enabled-state through the same store.setEnabled.
// No new model, no native, no seam change. It's presented as a sheet over the
// Homepage on first run, and re-openable later ("Take the tour" on the
// Dashboard), so it doubles as a rediscovery surface, not a one-shot.

struct FeatureTourView: View {
    @ObservedObject var store: SettingsStore
    let onClose: () -> Void

    @State private var index = 0

    /// The tour deck: every loadable feature, ordered by context bucket (typing,
    /// windows, web, anywhere, automatic) so the reel flows by scenario rather
    /// than registration order. Failed plugins are skipped (nothing to preview,
    /// can't be enabled). Read fresh each render so a card's `enabled` reflects
    /// the Add the user just made.
    private var deck: [FeatureInfo] {
        store.features
            .filter { !$0.failed }
            .sorted { a, b in
                let ca = FeatureContext(a.context).order, cb = FeatureContext(b.context).order
                return ca != cb ? ca < cb : a.name < b.name
            }
    }

    private var current: FeatureInfo? {
        let d = deck
        guard !d.isEmpty else { return nil }
        return d[min(max(index, 0), d.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let f = current {
                card(f)
            } else {
                Text(Strings.t("tour.noFeatures", default: "No features to show."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 600)
    }

    // MARK: top bar (title, progress, close)

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hammer.fill").foregroundStyle(.tint)
                Text(Strings.t("tour.title", default: "Discover Features")).font(.headline)
                Spacer()
                if !deck.isEmpty {
                    Text(String(format: Strings.t("tour.progress", default: "%1$d of %2$d"), min(index + 1, deck.count), deck.count))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Strings.t("tour.closeHelp", default: "Close the tour -- you can reopen it from Home"))
            }
            ProgressView(value: Double(index + 1), total: Double(max(deck.count, 1)))
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
    }

    // MARK: one feature card

    @ViewBuilder private func card(_ f: FeatureInfo) -> some View {
        let archetype = FeatureArchetype.of(f)
        // A FEATURE is tinted by its category, everywhere -- Settings row, Gallery
        // card, Timeline dot, and here. `FeatureContext.color` is SECTION chrome
        // (the Gallery's headers and filter chips, the badge below), and stays
        // that. This card used to take the context color for the feature itself,
        // which made one feature two colors depending on which view you were in;
        // invisible while 17 of 22 categories were the same blue, obvious once
        // they weren't. The split is deliberate: the tint says what KIND of thing
        // this is, the badge says WHEN it applies.
        let tint = categoryColor(f.category)
        VStack(spacing: 16) {
            // The large preview band. Auto-plays (unlike the Gallery's hover-gated
            // card) so the tour reads like a reel. `.none` archetypes (none today)
            // fall back to a big category glyph so the card still has a subject.
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(tint.opacity(0.08))
                RoundedRectangle(cornerRadius: 14)
                    .stroke(tint.opacity(0.18), lineWidth: 1)
                if case .none = archetype {
                    Image(systemName: featureIcon(f))
                        .font(.system(size: 64))
                        .foregroundStyle(tint.opacity(0.7))
                } else {
                    archetype.scene(playing: true)
                        .padding(14)
                }
            }
            .frame(height: 280)
            .padding(.horizontal, 18)
            .id(f.id)   // restart the scene's animation when the feature changes

            VStack(spacing: 8) {
                // The scenario line -- "when does this kick in" -- is the lead, so a
                // user grasps WHEN to reach for the feature before the name.
                contextBadge(FeatureContext(f.context))
                HStack(spacing: 8) {
                    if !f.actions.isEmpty {
                        let glyph = shortcutGlyph(f.actions.first?.trigger)
                        if !glyph.isEmpty {
                            ShortcutPill(glyph: glyph)
                        }
                    } else {
                        Label(Strings.t("tour.alwaysOn", default: "always on"), systemImage: "infinity")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(unmetRequirements(f), id: \.self) { r in
                        RequirementBadge(
                            label: String(format: Strings.t("tour.grant", default: "%@ — Grant"), requirementLabel(r)),
                            help: Strings.t("tour.grantHelp", default: "Open System Settings to grant Accessibility, then it works"),
                            action: { store.promptAccessibility() })
                    }
                    if f.recommended {
                        Label(Strings.t("tour.recommended", default: "Recommended"), systemImage: "star.fill")
                            .font(.caption2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.yellow.opacity(0.16)))
                            .foregroundStyle(.orange)
                    }
                }
                Text(f.name).font(.title2.weight(.semibold))
                Text(f.description.isEmpty ? Strings.t("tour.noDescription", default: "No description.") : f.description)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            Spacer(minLength: 0)
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func contextBadge(_ ctx: FeatureContext) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ctx.icon).font(.caption)
            Text(ctx.scenario).font(.caption.weight(.medium))
        }
        .foregroundStyle(ctx.color)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(ctx.color.opacity(0.12)))
    }

    // MARK: footer (Back, Add, Next/Done)

    private var footer: some View {
        HStack(spacing: 12) {
            Button { go(-1) } label: {
                Label(Strings.t("tour.back", default: "Back"), systemImage: "chevron.left")
            }
            .disabled(index == 0)

            Spacer()

            if let f = current {
                addButton(f)
            }

            Spacer()

            if index >= deck.count - 1 {
                Button { onClose() } label: {
                    Text(Strings.t("tour.done", default: "Done")).frame(minWidth: 56)
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button { go(1) } label: {
                    Label(Strings.t("tour.next", default: "Next"), systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabelStyle())
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    /// The one decision per card. Disabled feature -> a prominent "Add" that
    /// enables AND advances (the "see it, want it, click" flow). Enabled -> an
    /// "Added" affordance the user can tap to undo, without leaving the card.
    @ViewBuilder private func addButton(_ f: FeatureInfo) -> some View {
        if f.enabled {
            Button { store.setEnabled(f.id, false) } label: {
                Label(Strings.t("tour.added", default: "Added"), systemImage: "checkmark.circle.fill")
                    .frame(minWidth: 120)
            }
            .tint(.green)
            .help(Strings.t("tour.addedHelp", default: "In your deck -- click to remove"))
        } else {
            Button {
                store.requestSetEnabled(f.id, true)
                go(1)
            } label: {
                Label(Strings.t("tour.add", default: "Add"), systemImage: "plus")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .help(String(format: Strings.t("tour.enable", default: "Enable %@"), f.name))
        }
    }

    /// Preconditions not yet satisfied -- a granted permission drops off so the
    /// pill (and its Grant button) only shows while it's actually needed.
    private func unmetRequirements(_ f: FeatureInfo) -> [String] {
        f.requires.filter { req in
            switch req {
            case "accessibility": return !store.axTrusted
            default:              return true
            }
        }
    }

    private func go(_ delta: Int) {
        let d = deck
        guard !d.isEmpty else { return }
        index = min(max(index + delta, 0), d.count - 1)
    }
}

/// A label that puts its icon AFTER the title (for a "Next ›" button).
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}
