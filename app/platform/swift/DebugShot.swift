#if DEBUG
import AppKit
@preconcurrency import ScreenCaptureKit

/// App-owned visual verification. Compositor capture preserves native materials;
/// view rendering exports a scroll document at full height. DEBUG-only host
/// infrastructure (a peer of DebugControl), never a feature API.
@MainActor
enum DebugShot {
    static func setAppearance(_ mode: String) -> String {
        guard AppearancePreference.modes.contains(mode) else { return "ERROR: unknown appearance" }
        NSApp.appearance = AppearancePreference.appearance(for: mode)
        return "temporary appearance: \(mode)"
    }

    static func resizeWindow(_ size: String) -> String {
        let parts = size.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, (960...3840).contains(parts[0]), (560...2160).contains(parts[1]),
              let window = targetWindow() else { return "ERROR: expected window size 960x560 through 3840x2160" }
        window.setContentSize(NSSize(width: parts[0], height: parts[1]))
        return "window content: \(window.contentLayoutRect)"
    }

    static func scrollDetail(_ value: String) -> String {
        guard let fraction = Double(value), (0...1).contains(fraction),
              let content = targetWindow()?.contentView,
              let document = detailScrollDocument(in: content, verticalOnly: true),
              let scroll = document.enclosingScrollView else {
            return "ERROR: expected scroll fraction 0 through 1 and a vertical document"
        }
        let clip = scroll.contentView
        let travel = max(0, document.bounds.height - clip.bounds.height)
        let y = document.bounds.minY + travel * (document.isFlipped ? fraction : 1 - fraction)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
        return "document visible: \(document.visibleRect)"
    }

    /// Compositor pixels preserve native materials. The current-process query and
    /// exact window id keep this capture within the app's own content.
    static func captureWindow(to path: String, deadline: ContinuousClock.Instant) async -> String {
        guard #available(macOS 14.4, *) else { return "ERROR: window capture needs macOS 14.4" }
        guard let window = targetWindow() else { return "ERROR: no window to capture" }
        let id = CGWindowID(window.windowNumber)
        do {
            let content = try await SCShareableContent.currentProcess
            guard ContinuousClock.now < deadline else { return "ERROR: window capture timed out" }
            guard let owned = content.windows.first(where: {
                $0.windowID == id && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
            }) else { return "ERROR: own window unavailable for capture" }
            let filter = SCContentFilter(desktopIndependentWindow: owned)
            let config = SCStreamConfiguration()
            config.width = Int(ceil(filter.contentRect.width * Double(filter.pointPixelScale)))
            config.height = Int(ceil(filter.contentRect.height * Double(filter.pointPixelScale)))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.ignoreGlobalClipSingleWindow = true
            let captured: CGImage
            do {
                captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                let fault = error as NSError
                guard fault.domain == SCStreamErrorDomain,
                      fault.code == SCStreamError.internalError.rawValue,
                      ContinuousClock.now.advanced(by: .milliseconds(200)) < deadline else { throw error }
                NSLog("[windowshot] retrying internal stream failure: %@ (%ld)", fault.domain, fault.code)
                try await Task.sleep(for: .milliseconds(200))
                guard ContinuousClock.now < deadline else { return "ERROR: window capture timed out" }
                captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }
            guard ContinuousClock.now < deadline else { return "ERROR: window capture timed out" }
            let rep = NSBitmapImageRep(cgImage: captured)
            guard let png = rep.representation(using: .png, properties: [:]) else { return "ERROR: PNG encode failed" }
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            return "windowshot \(rep.pixelsWide)x\(rep.pixelsHigh) blank=\(looksBlank(rep)) -> \(path)"
        } catch { return "ERROR: window capture: \(error.localizedDescription)" }
    }

    /// Capture to `path`. Targets the rightmost scroll view's documentView (the
    /// Settings detail form) at full size; falls back to the whole content view.
    static func capture(to path: String) -> String {
        guard let window = targetWindow(), let content = window.contentView else {
            return "ERROR: no window to capture"
        }
        let view = detailScrollDocument(in: content) ?? content
        let bounds = view.bounds
        // NOTE: in DARK mode this capture is white-text-on-a-light-bitmap (unreadable):
        // cacheDisplay re-rasterizes SwiftUI's already-resolved (dark) layer colors, and
        // forcing the NSView's .appearance does NOT re-resolve them (SwiftUI bakes colors
        // at its own update cycle, not on a synchronous AppKit appearance change). The
        // workaround is to put the APP in light for the shot and restore after:
        // Settings > General > App > Appearance = Light. Flipping the whole SYSTEM
        // (adapter.setAppearance("light")) also works, but ONLY while that preference
        // is "system" -- a pinned NSApp.appearance ignores the system, so that route
        // silently no-ops for anyone who chose Light or Dark. A true in-process fix
        // would need a runloop-spin to re-render SwiftUI light -- a visible flicker,
        // not worth it for a debug tool.
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return "ERROR: could not make bitmap for \(bounds)"
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return "ERROR: PNG encode failed"
        }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch {
            return "ERROR: write failed: \(error)"
        }
        return "shot \(Int(bounds.width))x\(Int(bounds.height)) blank=\(looksBlank(rep)) -> \(path)"
    }

    /// A visible main-capable window (the homepage / Settings), preferring the
    /// key window, never a transient panel.
    private static func targetWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter {
            $0.isVisible && $0.canBecomeMain && !($0 is NSPanel)
        }
        return candidates.first { $0.isKeyWindow } ?? candidates.first
            ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    /// The detail content is the WIDEST scroll view's documentView -- the sidebar
    /// is a narrow (~184pt) column, the detail form / feature page is the wide
    /// one; ties break to the taller. (Width beats "rightmost": a feature page is
    /// a single detail ScrollView whose window-x can sit at the split, where a
    /// minX comparison mis-picks the sidebar.) The documentView holds the full,
    /// un-clipped content, so below-the-fold is captured without scrolling.
    private static func detailScrollDocument(in root: NSView, verticalOnly: Bool = false) -> NSView? {
        var docs: [NSView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, let d = s.documentView,
               !verticalOnly || d.bounds.height > s.contentSize.height + 1 { docs.append(d) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return docs.max { a, b in
            a.bounds.width != b.bounds.width
                ? a.bounds.width < b.bounds.width
                : a.bounds.height < b.bounds.height
        }
    }

    /// Sampling pitch in pixels for the blank detector. Prime, so the lattice
    /// cannot lock onto a regular layout rhythm (uniform row heights, card
    /// spacing) and keep landing on the same paint.
    private static let blankSamplePitch = 23

    /// Blank-render detector (the classic layer-backed cacheDisplay failure):
    /// sample the bitmap and report blank only if EVERY point is the same color.
    /// Real content (text, controls, dividers) always varies, so this flags a
    /// truly empty bitmap without false-positiving on a uniform background patch.
    ///
    /// Sampled at a fixed PITCH, not a fixed grid COUNT. A fixed count spreads
    /// its rows further apart the taller the image gets, so a tall sparse form
    /// -- the General settings pane, ~2800px of cards separated by wide gutters
    /// -- can put every sample in background and report blank on a perfectly
    /// good capture. That reading is worse than no reading: `blank=true` is
    /// documented as the "capture failed" signal, so it sends the reader after a
    /// broken screenshot pipeline instead of the content sitting in the PNG.
    static func looksBlank(_ rep: NSBitmapImageRep) -> Bool {
        guard rep.pixelsWide > 8, rep.pixelsHigh > 8 else { return true }
        var first: NSColor?
        var y = blankSamplePitch / 2
        while y < rep.pixelsHigh {
            var x = blankSamplePitch / 2
            while x < rep.pixelsWide {
                defer { x += blankSamplePitch }
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                guard let f = first else { first = c; continue }
                if abs(c.redComponent - f.redComponent) > 0.02
                    || abs(c.greenComponent - f.greenComponent) > 0.02
                    || abs(c.blueComponent - f.blueComponent) > 0.02 { return false }
            }
            y += blankSamplePitch
        }
        return true
    }
}
#endif
