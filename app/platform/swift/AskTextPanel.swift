// Panels.swift split: one self-owned native UI surface (see Panels.swift
// for the shared KeyablePanel base and the rationale for our own panels).

import AppKit

// MARK: - AskText (one-shot floating text prompt)

/// A floating single-line text prompt: Enter submits the text, Escape cancels
/// (submit nil). Mirrors the chooser's keyable-without-activating behavior.
@MainActor
final class AskTextPanel: NSObject, NSTextFieldDelegate {
    private let panel: KeyablePanel
    private let field = NSTextField()
    private let onSubmit: (String?) -> Void
    private var done = false

    init(title: String, placeholder: String, defaultValue: String,
         onSubmit: @escaping (String?) -> Void) {
        self.onSubmit = onSubmit
        let width: CGFloat = 420
        let height: CGFloat = 92
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        super.init()

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.hidesOnDeactivate = false

        let content = NSVisualEffectView()
        content.material = .menu
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let head = NSTextField(labelWithString: title)
        head.font = .boldSystemFont(ofSize: 14)
        head.frame = NSRect(x: 16, y: height - 32, width: width - 32, height: 18)
        content.addSubview(head)

        field.placeholderString = placeholder
        field.stringValue = defaultValue
        field.font = .systemFont(ofSize: 16)
        field.focusRingType = .none
        field.delegate = self
        field.frame = NSRect(x: 16, y: 18, width: width - 32, height: 28)
        content.addSubview(field)

        panel.contentView = content
        panel.center()
        if let screen = NSScreen.main {
            var f = panel.frame
            f.origin.y = screen.visibleFrame.midY + 80
            panel.setFrame(f, display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finish(field.stringValue); return true
        case #selector(NSResponder.cancelOperation(_:)):
            finish(nil); return true
        default:
            return false
        }
    }

    /// Programmatic cancel that still fires onSubmit(nil) (dismiss semantics).
    func dismiss() { finish(nil) }

    /// Silent close (stop semantics): no callback.
    func close() {
        done = true
        panel.orderOut(nil)
    }

    private func finish(_ text: String?) {
        guard !done else { return }
        done = true
        panel.orderOut(nil)
        onSubmit(text)
    }
}
