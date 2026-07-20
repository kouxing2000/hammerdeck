import SwiftUI

// Standalone "status card" feature scenes -- the password generator's reveal and
// the usage-stats dashboard. Each is a single-feature card with no shared sample
// type. Part of the FeatureArchetype scene set; the core enum + dispatch live in
// FeatureArchetypeAnimation.swift.

// MARK: - Password-reveal effect (password generator)

/// Previews password_generator's effect: characters scramble, lock into a strong
/// password, the strength meter fills, then a "Copied" check flashes (it copies
/// to the clipboard). Pure motion. Plays only while `playing` (hover); at rest it
/// shows the settled password (the calm frame).
struct PasswordRevealArchetypeScene: View {
    let playing: Bool

    // The last frame is the locked password; earlier frames are scramble noise of
    // the same length so the field doesn't jump width.
    private let frames = ["q2$xZ9wK", "7Kp#4mR8", "v8!Lr3nP", "Hk7$mP9w"]
    private let cycle = 6     // 0..2 scramble, 3 locked, 4 copied, 5 hold
    @State private var step = 0

    private var state: Int { step % cycle }
    private var locked: Bool { state >= 3 }
    private var copied: Bool { state == 4 || state == 5 }
    private var shownText: String {
        guard playing else { return frames.last! }
        return locked ? frames.last! : frames[state % (frames.count - 1)]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.18), lineWidth: 1))

            VStack(spacing: 6) {
                // the password field
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(locked ? Color.accentColor : .secondary)
                    Text(shownText)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(locked ? .primary : .secondary)
                    Spacer(minLength: 0)
                    if copied {
                        HStack(spacing: 2) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Copied").font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke((locked ? Color.accentColor : .secondary).opacity(0.4), lineWidth: 1))

                // strength meter: fills as the password locks in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule()
                            .fill(locked ? Color.green : Color.secondary.opacity(0.25))
                            .frame(height: 3)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state)
        .heartbeat(0.32, active: playing) { step += 1 }
        .onChange(of: playing) { isOn in
            if !isOn { step = 0 }   // settle to the locked-password calm frame
        }
    }
}

// MARK: - Usage-chart effect (usage stats)

/// Previews usage_stats: a little "today" dashboard whose per-app focus-time bars
/// grow in -- so the card says "see where your time goes" at a glance, not just
/// "tracks usage". Pure motion with fixed sample apps. Plays only while `playing`
/// (hover); at rest the bars rest filled (the calm frame).
struct UsageChartArchetypeScene: View {
    let playing: Bool

    private struct Bar { let glyph: String; let label: String; let value: Double; let time: String }
    private let bars = [
        Bar(glyph: "chevron.left.forwardslash.chevron.right", label: "Code",   value: 1.0,  time: "2h"),
        Bar(glyph: "globe",                                   label: "Chrome", value: 0.62, time: "1h"),
        Bar(glyph: "message",                                 label: "Slack",  value: 0.34, time: "40m"),
    ]

    @State private var grown = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Today").font(.system(size: 9, weight: .semibold))
                Spacer(minLength: 0)
                Text("3h 40m").font(.system(size: 8)).foregroundStyle(.secondary)
            }
            ForEach(0..<bars.count, id: \.self) { i in barRow(bars[i]) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.18), lineWidth: 1))
        // Start empty so the FIRST beat is the bars GROWING (the story -- time
        // accruing); starting from the filled calm frame made the first motion
        // them draining. The spring is already at the tick, so the seed is silent.
        .heartbeat(1.6, active: playing, onStart: { grown = false }) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { grown.toggle() }
        }
        .onChange(of: playing) { isOn in
            // Animated: the rest-settle is a transition the user watches, not a seed.
            if !isOn { withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { grown = true } }
        }
    }

    private func barRow(_ bar: Bar) -> some View {
        HStack(spacing: 5) {
            Image(systemName: bar.glyph)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Text(bar.label).font(.system(size: 8)).frame(width: 36, alignment: .leading)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.15)).frame(height: 6)
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(height: 6)
                    .scaleEffect(x: grown ? bar.value : 0.03, anchor: .leading)
            }
            Text(bar.time).font(.system(size: 7)).foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
        }
    }
}
