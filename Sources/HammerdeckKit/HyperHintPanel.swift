// Panels.swift split: one self-owned native UI surface (see Panels.swift for
// the shared base and the rationale for our own panels).

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

    private let panel: NSPanel

    init(rows: [Row]) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        // Real macOS vibrancy, clipped to a rounded rect; the panel casts the shadow.
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 12, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(titleLabel("⌃⌥⌘  Hyper"))
        stack.addArrangedSubview(gridView(rows))
        stack.addArrangedSubview(captionLabel("press a shortcut  ·  release Caps to dismiss"))

        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        effect.layoutSubtreeIfNeeded()
        let fit = stack.fittingSize
        let w = max(280, fit.width)
        let h = fit.height
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: screen.midX - w / 2,
                              y: screen.minY + screen.height * 0.30,
                              width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }

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
            return captionLabel("No Hyper shortcuts enabled")
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
        let label = NSTextField(labelWithString: KeyGlyphs.glyph(r.key) + (r.chord ? "\u{2026}" : ""))
        label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let cap = NSView()
        cap.wantsLayer = true
        cap.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        cap.layer?.cornerRadius = 5
        cap.layer?.borderWidth = 1
        cap.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        cap.translatesAutoresizingMaskIntoConstraints = false
        cap.addSubview(label)

        let h: CGFloat = 23
        NSLayoutConstraint.activate([
            cap.heightAnchor.constraint(equalToConstant: h),
            label.centerXAnchor.constraint(equalTo: cap.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: h),
        ])
        let fit = cap.widthAnchor.constraint(equalTo: label.widthAnchor, constant: 14)
        fit.priority = .defaultHigh
        fit.isActive = true
        return cap
    }
}
