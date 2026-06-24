import SwiftUI

// Full-screen / desktop-surface effects: the screen going dark (sleep / display
// off), a countdown strip depleting along the edge, and the wallpaper crossfade.
// Each previews the visible EFFECT, not the trigger -- a clock/ring would only
// say "runs on a schedule". Part of the FeatureArchetype scene set; the core
// enum + dispatch live in FeatureArchetypeAnimation.swift.

// MARK: - Screen-off effect (system sleep / display off)

/// The per-feature face of the screen-off effect: the glyph + label shown once
/// the screen has gone dark (a moon for sleep, a power icon for display-off).
struct ScreenOffSample {
    let glyph: String
    let label: String

    static let sleep      = ScreenOffSample(glyph: "moon.fill",  label: "Asleep")
    static let displayOff = ScreenOffSample(glyph: "powersleep", label: "Display off")
}

/// Previews the EFFECT: a lit desktop fades to black, the feature's glyph + label
/// surface on the dark screen, then it wakes -- looping. Plays only while
/// `playing` (hover); at rest it shows the lit desktop (the calm frame).
struct ScreenOffArchetypeScene: View {
    let sample: ScreenOffSample
    let playing: Bool

    @State private var dark = false

    var body: some View {
        ZStack {
            // a lit desktop: subtle wallpaper + a menubar strip + a window
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.18), .secondary.opacity(0.06)],
                                     startPoint: .top, endPoint: .bottom))
            VStack(spacing: 0) {
                Rectangle().fill(.secondary.opacity(0.18)).frame(height: 7)
                Spacer(minLength: 0)
            }
            RoundedRectangle(cornerRadius: 3)
                .fill(.background.opacity(0.7))
                .frame(width: 46, height: 26)

            // the screen-off overlay
            RoundedRectangle(cornerRadius: 6)
                .fill(.black)
                .opacity(dark ? 0.92 : 0)
            VStack(spacing: 3) {
                Image(systemName: sample.glyph)
                    .font(.system(size: 15, weight: .medium))
                Text(sample.label).font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.85))
            .opacity(dark ? 1 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.18), lineWidth: 1))
        .animation(.easeInOut(duration: 0.55), value: dark)
        .heartbeat(1.4, active: playing) { dark.toggle() }
        .onChange(of: playing) { isOn in
            if !isOn { dark = false }   // settle back to the lit calm frame
        }
    }
}

// MARK: - Countdown progress-strip effect

/// Previews count_down's actual effect: a thin progress strip runs along the top
/// edge of the screen and depletes to nothing, then repeats. Plays only while
/// `playing` (hover); at rest it shows the full strip (the calm frame).
struct CountdownStripArchetypeScene: View {
    let playing: Bool

    private let cycle = 5   // states 0..4; remaining = (cycle-1-state)/(cycle-1)
    @State private var step = 0

    private var remaining: Double {
        let state = step % cycle
        return Double(cycle - 1 - state) / Double(cycle - 1)   // 1 -> 0
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                // the desktop
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.18), lineWidth: 1))

                // the thin progress strip along the top edge
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, (playing ? remaining : 1) * (w - 12)), height: 4)
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                    .animation(.linear(duration: 0.5), value: step)

                // remaining-time label, centered
                Text(playing ? "\(Int((remaining * 3).rounded(.up)))m" : "3m")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .heartbeat(0.55, active: playing) { step += 1 }
        .onChange(of: playing) { isOn in
            if !isOn { step = 0 }   // reset to the full-strip calm frame
        }
    }
}

// MARK: - Wallpaper-swap effect (bing daily)

/// Previews bing_daily: the desktop wallpaper crossfades from one photo to a
/// fresh one -- so the card reads "new wallpaper every day," not just "appearance
/// feature." The photos are stylized landscapes (sky gradient + sun + ridge).
/// Pure motion. Plays only while `playing` (hover); at rest it shows the first.
struct WallpaperSwapArchetypeScene: View {
    let playing: Bool

    @State private var second = false

    var body: some View {
        ZStack(alignment: .top) {
            landscape(sky: [Color(red: 0.99, green: 0.74, blue: 0.42), Color(red: 0.96, green: 0.45, blue: 0.45)],
                      sun: Color(red: 1, green: 0.93, blue: 0.7), ridge: Color(red: 0.55, green: 0.27, blue: 0.35))
            landscape(sky: [Color(red: 0.45, green: 0.69, blue: 0.98), Color(red: 0.28, green: 0.45, blue: 0.78)],
                      sun: Color(red: 0.92, green: 0.97, blue: 1), ridge: Color(red: 0.2, green: 0.32, blue: 0.5))
                .opacity(second ? 1 : 0)

            // menubar strip so it reads as a real desktop
            Rectangle().fill(.black.opacity(0.18)).frame(height: 7)

            // "daily photo" badge, bottom-trailing
            HStack(spacing: 3) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 7, weight: .bold))
                Text("Daily").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.35)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.18), lineWidth: 1))
        .animation(.easeInOut(duration: 0.7), value: second)
        .heartbeat(1.9, active: playing) { second.toggle() }
        .onChange(of: playing) { isOn in
            if !isOn { second = false }   // settle to the first wallpaper
        }
    }

    private func landscape(sky: [Color], sun: Color, ridge: Color) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: sky, startPoint: .top, endPoint: .bottom)
                // sun
                Circle().fill(sun)
                    .frame(width: h * 0.28, height: h * 0.28)
                    .position(x: w * 0.74, y: h * 0.34)
                // a ridge of hills along the bottom
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h * 0.72))
                    p.addLine(to: CGPoint(x: w * 0.32, y: h * 0.84))
                    p.addLine(to: CGPoint(x: w * 0.6, y: h * 0.66))
                    p.addLine(to: CGPoint(x: w, y: h * 0.82))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.closeSubpath()
                }
                .fill(ridge)
            }
        }
    }
}
