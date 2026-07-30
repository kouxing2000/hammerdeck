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
    ///
    /// `lockSize`: after sizing, clamp the window's content size (min == max ==
    /// the presented size) so AppKit's auto-resize-to-fit-content is pinned and
    /// the frame can NEVER change afterward. Use it for a HUD whose content
    /// mutates while shown (HyperHint's hover hint), so nothing it does can grow
    /// or shift the card. Off for the static HUDs.
    @discardableResult
    func present(minWidth: CGFloat, lockSize: Bool = false) -> CGFloat {
        effect.layoutSubtreeIfNeeded()
        let fit = stack.fittingSize
        let w = max(minWidth, fit.width)
        let h = fit.height
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        setFrame(NSRect(x: screen.midX - w / 2,
                        y: screen.minY + screen.height * 0.30,
                        width: w, height: h), display: true)
        if lockSize {
            contentMinSize = NSSize(width: w, height: h)
            contentMaxSize = NSSize(width: w, height: h)
        }
        orderFrontRegardless()
        return w
    }
}

extension NSColor {
    /// A two-form color, for a DESIGN color with no semantic equivalent (a card
    /// fill, a chart accent). For anything the system already names -- label,
    /// separator, controlAccent -- use the semantic color and let `TintedView`
    /// apply any alpha; don't hand-copy its values here, or they drift when Apple
    /// retunes them.
    ///
    /// The name is the color's IDENTITY: two colors built with the same name
    /// compare EQUAL even with different bodies (measured), so give each its own.
    static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

}

/// A layer-backed rect that re-resolves its own colors when the theme flips --
/// use it for any divider, pill or band whose color comes from a semantic or
/// dynamic NSColor.
///
/// Why it exists rather than assigning `.cgColor` to a layer directly: a CGColor
/// is a RESOLVED value, not a promise, so a layer color set once is frozen at
/// whatever appearance was current when it was assigned. For a panel rebuilt on
/// every show that is harmless. For one that OUTLIVES a theme flip -- a chooser
/// handle is created when its feature is enabled and reused for the app's whole
/// run -- the frozen color is a bug that surfaces hours later: macOS switches
/// light/dark on its own schedule (System Settings > Appearance > Auto), so the
/// divider baked at 09:00 is still the light one at sunset. Holding the NSColor
/// and painting in `updateLayer` fixes it structurally: AppKit's default
/// `viewDidChangeEffectiveAppearance` invalidates the view, and inside
/// `updateLayer` the current drawing appearance IS the view's, so a plain
/// `.cgColor` there resolves against the NEW theme.
///
/// It handles two AppKit traps for its callers, which is why an alpha goes in the
/// `fillAlpha`/`strokeAlpha` field rather than into the color you pass:
///
///   - **Apply alpha LATE.** `NSColor.labelColor.withAlphaComponent(0.10)` is the
///     obvious spelling and it is a trap: `labelColor` is an NSDynamicSystemColor,
///     the alpha form is a static `_NSTaggedPointerColor`. It is not *incurably*
///     static though -- it is resolved at CONSTRUCTION, so built inside the right
///     drawing appearance it is correct. Measured: built early it is black@0.10 in
///     both themes; built late, black@0.10 under aqua and white@0.10 under
///     darkAqua. `updateLayer` runs at exactly that moment, so the alpha is
///     applied here and the caller passes the whole semantic color.
///   - **Fold VIBRANCY.** A subview of a `.menu` NSVisualEffectView has a vibrant
///     appearance, and a semantic color's vibrant form can be a different color
///     rather than a different shade: `.separatorColor` measures OPAQUE gray 0.14
///     under vibrantDark against white@0.098 under plain darkAqua (and opaque
///     0.90 under vibrantLight). Resolving against the view as-is therefore turns
///     a light hairline into a dark rule -- measured 0.48 -> 0.18 luminance on a
///     0.41 card, which is exactly what happened the first time these dividers
///     moved onto this class. So resolution is pinned to the PLAIN appearance via
///     `bestMatch(from: [.aqua, .darkAqua])`, which also folds the accessibility
///     high-contrast names onto their plain equivalents.
final class TintedView: NSView {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    /// nil = use `fill`'s own alpha. Set it to apply an alpha to a SEMANTIC color
    /// (see the class note -- doing it at the call site freezes the theme).
    var fillAlpha: CGFloat? { didSet { needsDisplay = true } }
    /// nil clears the border color; `borderWidth` stays the caller's business.
    var stroke: NSColor? { didSet { needsDisplay = true } }
    var strokeAlpha: CGFloat? { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }

    /// Own `wantsLayer` rather than trusting callers: with no layer-backed
    /// ancestor, `layer` is nil and `updateLayer` silently paints nothing.
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func updateLayer() {
        // The view's own appearance may be vibrant; resolve against its plain
        // equivalent instead (see the class note).
        let plain = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            .flatMap(NSAppearance.init(named:)) ?? effectiveAppearance
        plain.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Self.resolve(fill, fillAlpha).cgColor
            layer?.borderColor = stroke.map { Self.resolve($0, strokeAlpha).cgColor }
        }
    }

    private static func resolve(_ color: NSColor, _ alpha: CGFloat?) -> NSColor {
        alpha.map(color.withAlphaComponent) ?? color
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
