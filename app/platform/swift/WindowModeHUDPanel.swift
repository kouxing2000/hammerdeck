// Panels.swift split: one self-owned native UI surface (see Panels.swift for
// the shared FloatingPanel / VibrancyHUDPanel base and the rationale for our
// own panels).

import AppKit

// MARK: - Window Mode HUD (spatial cheat-sheet for a modal arranging layer)

/// A dark vibrancy HUD card (originally Window Mode's red-banner replacement,
/// now a generic cols x rows renderer also driving window_grid). Its hero is a
/// spatial grid map -- each cell holds the key(s) that drop the focused window
/// into that region (Window Mode: H = left half, Y = NW corner, F/C = center;
/// window_grid: a cell digit) so the layout teaches itself -- with grouped
/// key-cap rows beneath for the non-spatial keys (nudge / resize / screen / undo).
///
/// Content is fully data-driven from the feature (`window_modal` builds the
/// spec, it crosses the seam as a plain table) so this stays a generic renderer
/// and the cheat-sheet can't drift from the bindings without the feature
/// changing both. Non-activating and mouse-transparent, like BannerPanel /
/// ChordHintPanel -- purely informational, never steals focus.
@MainActor
final class WindowModeHUDPanel {
    /// One cell of the spatial map: its grid position (0-based, origin top-left)
    /// and the key glyph(s) that land a window there, with an optional caption.
    /// `state` (window_grid's extend phase) styles the cell: "corner" (the picked
    /// top-left), "valid" (a legal second corner), "dim" (an invalid cell); nil
    /// renders neutral (Window Mode, and the grid's initial phase). `preview` (a
    /// corner/valid cell in the extend phase) is the window that pressing it makes,
    /// as unit fractions {x,y,w,h} of the grid -- drawn as a mini-screen thumbnail.
    struct Cell {
        let col: Int; let row: Int; let keys: [String]; let label: String?
        let state: String?; let preview: CGRect?
    }
    /// One legend row: a group label and the keys it covers.
    struct Group { let label: String; let keys: [String] }

    struct Spec {
        let title: String
        let cols: Int
        let rows: Int
        let cells: [Cell]
        let caption: String?
        let groups: [Group]
        let footer: String?

        /// Parse the loosely-typed table that crosses the Lua seam.
        init(_ dict: [String: Any]) {
            title = dict["title"] as? String ?? "Window Mode"
            // Grid size is data-driven so the spatial map fits any N x M (e.g.
            // window_grid's 2x2 / 3x3); defaults to 3x3 for Window Mode, which
            // omits them. cols/rows are first-party integer literals; max(1,...)
            // floors them at 1 so diagramView's divisor can never reach zero.
            cols = max(1, (dict["cols"] as? Double).map { Int($0) } ?? 3)
            rows = max(1, (dict["rows"] as? Double).map { Int($0) } ?? 3)
            caption = dict["caption"] as? String
            footer = dict["footer"] as? String
            cells = (dict["cells"] as? [Any] ?? []).compactMap { Self.cell($0) }
            groups = (dict["groups"] as? [Any] ?? []).compactMap { Self.group($0) }
        }

        private static func keys(_ v: Any?) -> [String] {
            (v as? [Any])?.compactMap { $0 as? String } ?? []
        }
        private static func cell(_ v: Any) -> Cell? {
            guard let d = v as? [String: Any],
                  let col = d["col"] as? Double, let row = d["row"] as? Double else { return nil }
            return Cell(col: Int(col), row: Int(row), keys: keys(d["keys"]),
                        label: d["label"] as? String, state: d["state"] as? String,
                        preview: rect(d["preview"]))
        }
        /// A unit-fraction rect {x,y,w,h} crossing the seam -> CGRect (nil if absent).
        private static func rect(_ v: Any?) -> CGRect? {
            guard let d = v as? [String: Any],
                  let x = d["x"] as? Double, let y = d["y"] as? Double,
                  let w = d["w"] as? Double, let h = d["h"] as? Double else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        private static func group(_ v: Any) -> Group? {
            guard let d = v as? [String: Any], let label = d["label"] as? String else { return nil }
            return Group(label: label, keys: keys(d["keys"]))
        }
    }

    private let hud = VibrancyHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240))
    private var cols = 3
    private var rows = 3
    /// HUDScale factor of the screen the card is presented on (VibrancyHUDPanel
    /// presents on NSScreen.main), re-read on every render.
    private var s: CGFloat = 1

    init(spec: Spec) {
        render(spec, cols: spec.cols, rows: spec.rows)
    }

    /// Build the card's content from a spec. Clears the stack first, so it is
    /// safe to call repeatedly -- the ChordHintPanel.update pattern -- which is
    /// what lets `update(spec:)` restyle the map in place (e.g. window_grid
    /// highlighting the picked corner after the first keypress).
    private func render(_ spec: Spec, cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        s = HUDScale.factor(for: NSScreen.main)
        hud.effect.layer?.cornerRadius = 16 * s

        let stack = hud.stack
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.alignment = .centerX
        stack.spacing = 10 * s
        stack.edgeInsets = NSEdgeInsets(top: 14 * s, left: 18 * s, bottom: 12 * s, right: 18 * s)

        stack.addArrangedSubview(titleLabel(spec.title))
        stack.addArrangedSubview(diagramView(spec.cells))
        if let cap = spec.caption { stack.addArrangedSubview(captionLabel(cap)) }
        if !spec.groups.isEmpty { stack.addArrangedSubview(legendView(spec.groups)) }
        if let footer = spec.footer { stack.addArrangedSubview(captionLabel(footer)) }

        hud.present(minWidth: 300 * s)
    }

    /// Re-render the SAME live panel from a fresh spec (window_grid's mid-mode
    /// corner highlight + dimming). The grid DIMENSIONS are locked for the mode's
    /// lifetime, so an update restyles cells but never resizes the board -- reuse
    /// the dims captured at first render, so a partial update dict that omits
    /// cols/rows can't silently collapse a 2x2 board to the 3x3 default.
    func update(spec: Spec) { render(spec, cols: self.cols, rows: self.rows) }

    func close() { hud.orderOut(nil) }

    // MARK: - Pieces

    private func titleLabel(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s.uppercased())
        f.font = .systemFont(ofSize: 11 * self.s, weight: .semibold)
        f.textColor = .secondaryLabelColor
        f.alignment = .center
        // Letterspaced caps read as a HUD title, not a sentence.
        f.attributedStringValue = NSAttributedString(string: s.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11 * self.s, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 1.8 * self.s])
        return f
    }

    private func captionLabel(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 10 * self.s)
        f.textColor = .tertiaryLabelColor
        f.alignment = .center
        return f
    }

    /// The spatial grid map (cols x rows): a bordered "screen" with each cell's
    /// key-cap(s) centered where they snap.
    private func diagramView(_ cells: [Cell]) -> NSView {
        let cellW: CGFloat = 72 * s, cellH: CGFloat = 42 * s
        let pad: CGFloat = 6 * s
        let w = cellW * CGFloat(cols) + pad * 2
        let h = cellH * CGFloat(rows) + pad * 2

        let board = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        board.wantsLayer = true
        board.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        board.layer?.cornerRadius = 8 * s
        board.layer?.borderWidth = 1
        board.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        board.translatesAutoresizingMaskIntoConstraints = false
        board.widthAnchor.constraint(equalToConstant: w).isActive = true
        board.heightAnchor.constraint(equalToConstant: h).isActive = true

        for c in cells {
            // Grid is described top-left origin; AppKit's y grows upward, so flip the row.
            let cx = pad + (CGFloat(c.col) + 0.5) * cellW
            let cy = pad + (CGFloat(rows - 1 - c.row) + 0.5) * cellH
            let content = cellContent(c)
            content.setFrameSize(content.fittingSize)
            content.setFrameOrigin(NSPoint(x: cx - content.frame.width / 2,
                                           y: cy - content.frame.height / 2))
            board.addSubview(content)
        }
        return board
    }

    /// One cell's content. In window_grid's extend phase a corner/valid cell renders
    /// a mini-screen THUMBNAIL of the window it produces (a size preview); a "dim"
    /// (invalid) cell fades its digit; everything else (Window Mode, the grid's
    /// initial phase) is the plain key-cap(s) above an optional caption.
    private func cellContent(_ c: Cell) -> NSView {
        // A "dim" (invalid) cell never shows a bright thumbnail even if a caller
        // hands it a preview -- dimming wins, so it falls through to the faded
        // key-cap path below. (Today hudFor keeps preview and dim mutually
        // exclusive; this just makes the renderer independent of that invariant.)
        if let pv = c.preview, c.state != "dim" { return previewThumb(c, pv) }
        // window_grid's "corner" always carries a preview (handled above), so this
        // tint is a defensive fallback for a corner cell that lacks one (a future
        // caller styling a corner without a size preview).
        let tint: NSColor? = c.state == "corner" ? .controlAccentColor : nil
        let caps = NSStackView(views: c.keys.map { keyCap($0, tint: tint) })
        caps.orientation = .horizontal
        caps.spacing = 4 * s
        let content: NSView
        if let label = c.label {
            let v = NSStackView(views: [caps, captionLabel(label)])
            v.orientation = .vertical
            v.alignment = .centerX
            v.spacing = 2 * s
            content = v
        } else {
            content = caps
        }
        if c.state == "dim" { content.alphaValue = 0.22 }   // strong "invalid" suppression
        return content
    }

    /// A mini "screen" for a valid/corner cell: a bordered rect with the window
    /// that pressing this cell would produce (accent fill at the preview fractions)
    /// and the digit tucked in the corner. Corner-A gets the strongest border.
    /// `pv` is a unit rect (fractions of the grid); AppKit's y grows up, so flip.
    private func previewThumb(_ c: Cell, _ pv: CGRect) -> NSView {
        let sw: CGFloat = 46 * s, sh: CGFloat = 30 * s
        let isCorner = c.state == "corner"
        let screen = NSView()
        screen.wantsLayer = true
        screen.translatesAutoresizingMaskIntoConstraints = false
        // Resolve the dynamic accent/whites against the HUD's forced dark appearance
        // (a .cgColor snapshot would otherwise track the ambient appearance).
        (NSAppearance(named: .vibrantDark) ?? NSAppearance.currentDrawing())
            .performAsCurrentDrawingAppearance {
                screen.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
                screen.layer?.cornerRadius = 3 * s
                screen.layer?.borderWidth = isCorner ? 1.5 : 1
                screen.layer?.borderColor = NSColor.controlAccentColor
                    .withAlphaComponent(isCorner ? 0.95 : 0.5).cgColor
                let win = CALayer()
                let wx = pv.origin.x * sw
                let wy = (1 - pv.origin.y - pv.height) * sh          // flip to y-up
                let inset = 1.5 * s
                win.frame = CGRect(x: wx + inset, y: wy + inset,
                                   width: max(2 * s, pv.width * sw - 2 * inset),
                                   height: max(2 * s, pv.height * sh - 2 * inset))
                win.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
                win.cornerRadius = 1.5 * s
                screen.layer?.addSublayer(win)
            }
        let num = NSTextField(labelWithString: c.keys.first ?? "")
        num.font = .monospacedSystemFont(ofSize: 8 * s, weight: .bold)
        num.textColor = .white
        num.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(num)
        NSLayoutConstraint.activate([
            screen.widthAnchor.constraint(equalToConstant: sw),
            screen.heightAnchor.constraint(equalToConstant: sh),
            num.trailingAnchor.constraint(equalTo: screen.trailingAnchor, constant: -2 * s),
            num.topAnchor.constraint(equalTo: screen.topAnchor, constant: 0),
        ])
        // diagramView positions each cell by frame (setFrameSize(fittingSize) +
        // setFrameOrigin), which only STICKS for a translates=true child. `screen`
        // is Auto-Layout-sized (translates=false), so wrap it in a stack -- exactly
        // how the key-cap path wraps its constraint-sized caps -- to stay
        // frame-positionable while reporting its (scaled) 46x30 fittingSize. Without this the
        // thumbnails collapse to the board origin instead of landing in their cells.
        return NSStackView(views: [screen])
    }

    /// Grouped legend rows for the non-spatial keys.
    private func legendView(_ groups: [Group]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6 * s
        for g in groups { stack.addArrangedSubview(legendRow(g)) }
        return stack
    }

    private func legendRow(_ g: Group) -> NSView {
        let label = NSTextField(labelWithString: g.label)
        label.font = .systemFont(ofSize: 11 * s, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 86 * s).isActive = true

        let caps = NSStackView(views: g.keys.map { keyCap($0, fontSize: 11) })
        caps.orientation = .horizontal
        caps.spacing = 4 * s

        let row = NSStackView(views: [label, caps])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10 * s
        return row
    }

    /// A boxed key-cap: the glyph in a faint rounded rect, like a keyboard key.
    /// `tint` (window_grid's corner) accents the cap; nil stays neutral.
    /// `fontSize` is the unscaled design size; the HUDScale factor is applied here.
    private func keyCap(_ raw: String, fontSize: CGFloat = 13, tint: NSColor? = nil) -> NSView {
        KeyCap.make(KeyGlyphs.glyph(raw), fontSize: fontSize * s, height: (fontSize + 11) * s,
                    tint: tint, scale: s)
    }
}
