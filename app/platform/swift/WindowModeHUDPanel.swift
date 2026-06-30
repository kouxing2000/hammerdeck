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
    struct Cell { let col: Int; let row: Int; let keys: [String]; let label: String? }
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
                        label: d["label"] as? String)
        }
        private static func group(_ v: Any) -> Group? {
            guard let d = v as? [String: Any], let label = d["label"] as? String else { return nil }
            return Group(label: label, keys: keys(d["keys"]))
        }
    }

    private let hud = VibrancyHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240))
    private let cols: Int
    private let rows: Int

    init(spec: Spec) {
        cols = spec.cols
        rows = spec.rows

        let stack = hud.stack
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 12, right: 18)

        stack.addArrangedSubview(titleLabel(spec.title))
        stack.addArrangedSubview(diagramView(spec.cells))
        if let cap = spec.caption { stack.addArrangedSubview(captionLabel(cap)) }
        if !spec.groups.isEmpty { stack.addArrangedSubview(legendView(spec.groups)) }
        if let footer = spec.footer { stack.addArrangedSubview(captionLabel(footer)) }

        hud.present(minWidth: 300)
    }

    func close() { hud.orderOut(nil) }

    // MARK: - Pieces

    private func titleLabel(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s.uppercased())
        f.font = .systemFont(ofSize: 11, weight: .semibold)
        f.textColor = .secondaryLabelColor
        f.alignment = .center
        // Letterspaced caps read as a HUD title, not a sentence.
        f.attributedStringValue = NSAttributedString(string: s.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 1.8])
        return f
    }

    private func captionLabel(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 10)
        f.textColor = .tertiaryLabelColor
        f.alignment = .center
        return f
    }

    /// The spatial grid map (cols x rows): a bordered "screen" with each cell's
    /// key-cap(s) centered where they snap.
    private func diagramView(_ cells: [Cell]) -> NSView {
        let cellW: CGFloat = 72, cellH: CGFloat = 42
        let pad: CGFloat = 6
        let w = cellW * CGFloat(cols) + pad * 2
        let h = cellH * CGFloat(rows) + pad * 2

        let board = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        board.wantsLayer = true
        board.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        board.layer?.cornerRadius = 8
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

    /// One cell's caps (side by side) above an optional caption.
    private func cellContent(_ c: Cell) -> NSView {
        let caps = NSStackView(views: c.keys.map { keyCap($0) })
        caps.orientation = .horizontal
        caps.spacing = 4
        guard let label = c.label else { return caps }
        let v = NSStackView(views: [caps, captionLabel(label)])
        v.orientation = .vertical
        v.alignment = .centerX
        v.spacing = 2
        return v
    }

    /// Grouped legend rows for the non-spatial keys.
    private func legendView(_ groups: [Group]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for g in groups { stack.addArrangedSubview(legendRow(g)) }
        return stack
    }

    private func legendRow(_ g: Group) -> NSView {
        let label = NSTextField(labelWithString: g.label)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 86).isActive = true

        let caps = NSStackView(views: g.keys.map { keyCap($0, fontSize: 11) })
        caps.orientation = .horizontal
        caps.spacing = 4

        let row = NSStackView(views: [label, caps])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    /// A boxed key-cap: the glyph in a faint rounded rect, like a keyboard key.
    private func keyCap(_ raw: String, fontSize: CGFloat = 13) -> NSView {
        KeyCap.make(KeyGlyphs.glyph(raw), fontSize: fontSize, height: fontSize + 11)
    }
}
