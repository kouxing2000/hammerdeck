import SwiftUI

// Banner / modal archetype -- a notification/legend pill that slides in from the
// top edge. Part of the FeatureArchetype scene set; the core enum + dispatch
// live in FeatureArchetypeAnimation.swift.

/// The per-feature content a banner scene renders: an icon, a title, and a
/// short subtitle/legend. Like the chooser, the motion is shared and only this
/// differs between banner features.
struct BannerSample {
    let glyph: String
    let title: String
    let subtitle: String

    static let breakReminder = BannerSample(
        glyph: "eyes", title: "Time for a break", subtitle: "Rest your eyes for a moment")
}

/// A notification/legend pill that slides in from the top edge, holds, slides
/// back out, and loops -- the signature "a banner appears" motion. Plays only
/// while `playing` (hover); at rest it rests fully shown (the calm frame).
struct BannerArchetypeScene: View {
    let sample: BannerSample
    let playing: Bool

    @State private var shown = true   // calm frame = banner resting in view

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // a faint desktop backdrop so the slide reads against an edge
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary.opacity(0.06))

                banner
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    // slide up out of frame (above the top edge) when hidden
                    .offset(y: shown ? 0 : -(geo.size.height))
                    .opacity(shown ? 1 : 0)
                    .animation(.spring(response: 0.42, dampingFraction: 0.78), value: shown)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .heartbeat(1.3, active: playing) { shown.toggle() }
        .onChange(of: playing) { isOn in
            if !isOn { shown = true }   // settle back to the shown calm frame
        }
    }

    private var banner: some View {
        HStack(spacing: 7) {
            Image(systemName: sample.glyph)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(sample.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(sample.subtitle)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
    }
}
