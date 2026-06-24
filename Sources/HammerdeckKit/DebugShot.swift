#if DEBUG
import AppKit

/// In-process window capture for visual verification -- the app screenshots
/// ITSELF. Because we render our own view hierarchy directly into a bitmap, this
/// needs no Screen Recording permission, does not care whether the window is
/// frontmost / occluded / off-screen, and -- crucially -- can render a scroll
/// view's documentView at its FULL content height, so content below the fold is
/// included without any scrolling. DEBUG-only host infra (a peer of
/// DebugControl); never a feature API.
@MainActor
enum DebugShot {
    /// Capture to `path`. Targets the rightmost scroll view's documentView (the
    /// Settings detail form) at full size; falls back to the whole content view.
    static func capture(to path: String) -> String {
        guard let window = targetWindow(), let content = window.contentView else {
            return "ERROR: no window to capture"
        }
        let view = detailScrollDocument(in: content) ?? content
        let bounds = view.bounds
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

    /// The detail form is the RIGHTMOST scroll view (the sidebar's is on the
    /// left); its documentView holds the full, un-clipped form content.
    private static func detailScrollDocument(in root: NSView) -> NSView? {
        var scrolls: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { scrolls.append(s) }
            v.subviews.forEach(walk)
        }
        walk(root)
        // Rightmost by frame origin in window coordinates.
        let rightmost = scrolls.max { a, b in
            a.convert(a.bounds, to: nil).minX < b.convert(b.bounds, to: nil).minX
        }
        return rightmost?.documentView
    }

    /// Blank-render detector (the classic layer-backed cacheDisplay failure):
    /// sample a dense grid and report blank only if EVERY point is the same
    /// color. Real content (text, controls, dividers) always varies, so this
    /// flags a truly empty bitmap without false-positiving on a uniform
    /// background patch the way a handful of points would.
    private static func looksBlank(_ rep: NSBitmapImageRep) -> Bool {
        guard rep.pixelsWide > 8, rep.pixelsHigh > 8 else { return true }
        var first: NSColor?
        for gx in 1..<12 {
            for gy in 1..<12 {
                let x = rep.pixelsWide * gx / 13, y = rep.pixelsHigh * gy / 13
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                guard let f = first else { first = c; continue }
                if abs(c.redComponent - f.redComponent) > 0.02
                    || abs(c.greenComponent - f.greenComponent) > 0.02
                    || abs(c.blueComponent - f.blueComponent) > 0.02 { return false }
            }
        }
        return true
    }
}
#endif
