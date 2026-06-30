// Panels.swift split: one self-owned native UI surface (see Panels.swift for
// the shared FloatingPanel / VibrancyHUDPanel base and the rationale for our
// own panels).

import AppKit

// MARK: - Hyper which-key HUD (held-Caps cheat-sheet)

/// The held-Caps "which-key" legend: a dark vibrancy card listing every live
/// Hyper (⌘⌥⌃) shortcut as a key-cap + label, laid out in two balanced columns.
/// CapsHyperTap shows it after a short hold (so it only appears when you pause,
/// i.e. forgot the key) and tears it down on key-press or release. Styled to
/// match WindowModeHUDPanel / ChordHintPanel: non-activating, mouse-transparent,
/// purely informational, never steals focus.
@MainActor
final class HyperHintPanel {
    struct Row { let key: String; let label: String; let chord: Bool }

    private let hud = VibrancyHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200))

    init(rows: [Row]) {
        let stack = hud.stack
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 12, right: 18)

        stack.addArrangedSubview(titleLabel("⌃⌥⌘  Hyper"))
        stack.addArrangedSubview(gridView(rows))
        stack.addArrangedSubview(captionLabel(Strings.t("hyper.caption", default: "press a shortcut  ·  release Caps to dismiss")))

        hud.present(minWidth: 280)
    }

    func close() { hud.orderOut(nil) }

    // MARK: - Pieces

    private func titleLabel(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        // Letterspaced caps read as a HUD title, not a sentence.
        f.attributedStringValue = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 1.8])
        f.alignment = .center
        return f
    }

    private func captionLabel(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 10)
        f.textColor = .tertiaryLabelColor
        f.alignment = .center
        return f
    }

    /// Two balanced columns of [key-cap, label]; NSGridView aligns the caps and
    /// labels into tidy columns regardless of glyph/label width.
    private func gridView(_ rows: [Row]) -> NSView {
        guard !rows.isEmpty else {
            return captionLabel(Strings.t("hyper.empty", default: "No Hyper shortcuts enabled"))
        }
        let half = (rows.count + 1) / 2
        var gridRows: [[NSView]] = []
        for i in 0..<half {
            var cells: [NSView] = [keyCap(rows[i]), labelField(rows[i].label)]
            let j = i + half
            if j < rows.count {
                cells.append(keyCap(rows[j]))
                cells.append(labelField(rows[j].label))
            } else {
                cells.append(NSGridCell.emptyContentView)
                cells.append(NSGridCell.emptyContentView)
            }
            gridRows.append(cells)
        }
        let grid = NSGridView(views: gridRows)
        grid.rowSpacing = 7
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .center
        grid.column(at: 1).xPlacement = .leading
        if grid.numberOfColumns > 2 {
            grid.column(at: 2).xPlacement = .center
            grid.column(at: 2).leadingPadding = 18   // gap between the two columns
            grid.column(at: 3).xPlacement = .leading
        }
        return grid
    }

    private func labelField(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 12)
        f.textColor = .labelColor
        return f
    }

    /// A boxed key-cap: the glyph in a faint rounded rect, like a keyboard key.
    /// A chord prefix gets a trailing "…" (press, then a follow key).
    private func keyCap(_ r: Row) -> NSView {
        KeyCap.make(KeyGlyphs.glyph(r.key) + (r.chord ? "\u{2026}" : ""), fontSize: 12, height: 23)
    }
}
