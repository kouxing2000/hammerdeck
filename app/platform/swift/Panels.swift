import AppKit

// Self-owned UI surfaces for the native backend. We deliberately do NOT use
// UserNotifications here: it requires an app bundle + a permission prompt, and
// the M2 host is a bare SwiftPM executable. Our own floating panels need zero
// permissions and match the platform's overlay use cases (banner countdown,
// chooser dialogs). Revisit real Notification Center delivery in M3 when there
// is a signed .app bundle.

/// The shared base for every self-owned overlay (HUDs, banner, chooser, toast,
/// locator...). Bakes in the borderless + non-activating style, transparent
/// background, and opacity those panels otherwise hand-rolled identically; the
/// four axes that actually vary are constructor parameters:
///   - `level` -- window level (.statusBar overlays / .floating dialogs).
///   - `collectionBehavior` -- Spaces / full-screen / transient membership.
///   - `keyable` -- may take key input without activating the app (so a chooser
///      reads keystrokes while the user's app keeps focus). Drives canBecomeKey.
///   - `mouseTransparent` -- clicks pass straight through (informational HUDs)
///      vs. land in the panel (interactive chooser / text prompt).
/// `hasShadow` is left untouched unless a value is passed, so panels that relied
/// on the NSWindow default keep it.
class FloatingPanel: NSPanel {
    private let keyable: Bool
    override var canBecomeKey: Bool { keyable }

    init(contentRect: NSRect,
         level: NSWindow.Level = .statusBar,
         collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary],
         keyable: Bool = false,
         mouseTransparent: Bool = true,
         hasShadow: Bool? = nil) {
        self.keyable = keyable
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.level = level
        self.isOpaque = false
        self.backgroundColor = .clear
        self.collectionBehavior = collectionBehavior
        self.ignoresMouseEvents = mouseTransparent
        if let hasShadow { self.hasShadow = hasShadow }
    }
}

/// A FloatingPanel preset as a dark `.hudWindow` vibrancy card -- the rounded,
/// blurred HUD chrome shared verbatim by ChordHintPanel / HyperHintPanel /
/// WindowModeHUDPanel. Owns the visual-effect view and a vertical content
/// `stack` pinned to its edges; the caller sets the stack's alignment / spacing /
/// insets, fills it, then calls `present()`. Always a non-activating, mouse-
/// transparent, shadow-casting status-bar overlay.
final class VibrancyHUDPanel: FloatingPanel {
    let effect = NSVisualEffectView()
    let stack = NSStackView()

    init(contentRect: NSRect = NSRect(x: 0, y: 0, width: 240, height: 80)) {
        super.init(contentRect: contentRect, level: .statusBar,
                   keyable: false, mouseTransparent: true, hasShadow: true)
        // Real macOS vibrancy, clipped to a rounded rect; the panel casts the shadow.
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    /// Size to fit the stack (floored at `minWidth`) and show centered in the
    /// lower third of the main screen -- the present sequence all three HUDs
    /// share. Returns the final width (ChordHint sizes its depletion bar from it).
    @discardableResult
    func present(minWidth: CGFloat) -> CGFloat {
        effect.layoutSubtreeIfNeeded()
        let fit = stack.fittingSize
        let w = max(minWidth, fit.width)
        let h = fit.height
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        setFrame(NSRect(x: screen.midX - w / 2,
                        y: screen.minY + screen.height * 0.30,
                        width: w, height: h), display: true)
        orderFrontRegardless()
        return w
    }
}

/// A boxed key-cap: a glyph in a faint rounded rect, like a keyboard key -- the
/// chip the dark HUDs (ChordHint / HyperHint / WindowModeHUD) all draw.
/// `fixedWidth` pins the cap to a constant width so a column of single-key caps
/// aligns its labels; nil lets the cap hug its glyph. `tint` colors the cap
/// (fill / border / glyph) so a key reads as a distinct chip; nil gives the
/// neutral white cap. Resolved against the forced-dark HUD appearance.
/// (ChooserPanel keeps its own cap: a gray chip on `.menu` material that must
/// read in both light and dark -- a different style, not this one.)
@MainActor
enum KeyCap {
    static func make(_ glyph: String, fontSize: CGFloat, height: CGFloat,
                     fixedWidth: CGFloat? = nil, tint: NSColor? = nil) -> NSView {
        let base = tint ?? .white
        let label = NSTextField(labelWithString: glyph)
        label.font = .monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        // A tinted cap brightens its glyph to the color; neutral caps stay label-colored.
        label.textColor = tint.map { $0.blended(withFraction: 0.35, of: .white) ?? $0 } ?? .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let cap = NSView()
        cap.wantsLayer = true
        cap.layer?.cornerRadius = 5
        cap.layer?.borderWidth = 1
        // Resolve the (dynamic, catalog) system colors against the HUD's forced
        // dark appearance, not the ambient drawing appearance -- `.cgColor` is a
        // one-shot snapshot that would otherwise track whatever's current.
        let fill = base.withAlphaComponent(tint == nil ? 0.10 : 0.22)
        let stroke = base.withAlphaComponent(tint == nil ? 0.20 : 0.55)
        (NSAppearance(named: .vibrantDark) ?? NSAppearance.currentDrawing())
            .performAsCurrentDrawingAppearance {
                cap.layer?.backgroundColor = fill.cgColor
                cap.layer?.borderColor = stroke.cgColor
            }
        cap.translatesAutoresizingMaskIntoConstraints = false
        cap.addSubview(label)

        NSLayoutConstraint.activate([
            cap.heightAnchor.constraint(equalToConstant: height),
            label.centerXAnchor.constraint(equalTo: cap.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
        ])
        if let fw = fixedWidth {
            // Pin to fw for column alignment, but let a wide glyph grow rather
            // than clip (KeyGlyphs can return multi-char glyphs like arrows).
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: fw).isActive = true
            let pin = cap.widthAnchor.constraint(equalToConstant: fw)
            pin.priority = .defaultHigh
            pin.isActive = true
            cap.widthAnchor.constraint(greaterThanOrEqualTo: label.widthAnchor, constant: 14).isActive = true
        } else {
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
            let fit = cap.widthAnchor.constraint(equalTo: label.widthAnchor, constant: 14)
            fit.priority = .defaultHigh
            fit.isActive = true
        }
        return cap
    }
}
