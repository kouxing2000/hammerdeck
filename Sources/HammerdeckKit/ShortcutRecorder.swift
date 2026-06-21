import SwiftUI
import AppKit

// Shared hotkey-capture plumbing + a self-contained "record shortcut" control.
// Both the feature-settings TriggerEditor and the Shortcut Map grid drive their
// "press the keys" capture through ShortcutCapture, so the NSEvent monitor and
// the keyCode -> canonical-name mapping live in ONE place. The captured names
// match the native seam's vocabulary (HotkeyCenter): mods are "cmd"/"alt"/
// "ctrl"/"shift" and the key comes from Native.codeToKeyName ("left", "return",
// "j", ...), so the stored TriggerSpec binds without a translation step.

/// Bundles the resources one capture holds: the key-down monitor and a
/// resign-active observer. Carried back to `ShortcutCapture.end` as the token.
private final class CaptureToken {
    var eventMonitor: Any?
    var resignObserver: NSObjectProtocol?
}

enum ShortcutCapture {
    /// Begin a local key-down capture. On the first key, calls `onKey(mods,
    /// key)` with the captured combo; Escape calls `onCancel`. Returns the
    /// token (pass it to `end` to tear down). Main-thread only.
    ///
    /// Suspends all global hotkeys for the capture window so a combo already
    /// bound to a feature falls through to this monitor (gets RECORDED, and the
    /// editor warns it's taken) instead of firing that feature's action.
    /// Balanced by `end`. Also cancels if the app resigns active mid-capture
    /// (user clicked away without pressing a key) -- otherwise the hotkeys would
    /// stay suspended while they're in another app.
    @MainActor
    static func begin(onKey: @escaping (Set<String>, String) -> Void,
                      onCancel: @escaping () -> Void) -> Any? {
        HotkeyCenter.shared.suspend()
        let token = CaptureToken()
        token.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { ev in
            if ev.keyCode == 53 { onCancel(); return nil }   // Escape cancels
            var m: Set<String> = []
            let f = ev.modifierFlags
            if f.contains(.control) { m.insert("ctrl") }
            if f.contains(.option)  { m.insert("alt") }
            if f.contains(.shift)   { m.insert("shift") }
            if f.contains(.command) { m.insert("cmd") }
            let name = Native.codeToKeyName[Int(ev.keyCode)]
                ?? (ev.charactersIgnoringModifiers ?? "").lowercased()
            onKey(m, name)
            return nil   // swallow the captured event
        }
        token.resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { onCancel() } }
        return token
    }

    @MainActor
    static func end(_ monitor: Any?) {
        if let token = monitor as? CaptureToken {
            if let m = token.eventMonitor { NSEvent.removeMonitor(m) }
            if let o = token.resignObserver { NotificationCenter.default.removeObserver(o) }
        } else if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        HotkeyCenter.shared.resume()
    }
}

/// Canonical modifier order + display glyphs (cmd -> alt -> ctrl -> shift).
let kModSymbols: [(id: String, symbol: String)] =
    [("cmd", "⌘"), ("alt", "⌥"), ("ctrl", "⌃"), ("shift", "⇧")]

/// The selected modifier glyphs, in canonical order.
func shortcutModSymbols(_ mods: Set<String>) -> [String] {
    kModSymbols.filter { mods.contains($0.id) }.map(\.symbol)
}

/// A key name shown for display: arrows/return/etc. as their glyph, single
/// characters uppercased, everything else verbatim. "" for an empty key.
func shortcutKeyLabel(_ key: String) -> String {
    let k = key.trimmingCharacters(in: .whitespaces)
    if k.isEmpty { return "" }
    let named: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓",
        "return": "⏎", "enter": "⏎", "space": "␣", "escape": "⎋", "esc": "⎋",
        "tab": "⇥", "delete": "⌫", "backspace": "⌫", "forwarddelete": "⌦",
    ]
    if let glyph = named[k.lowercased()] { return glyph }
    return k.count == 1 ? k.uppercased() : k
}

/// The full combo string, e.g. "⌘ ⌥ ⌃ + ←", or `placeholder` when empty.
func shortcutCombo(_ mods: Set<String>, _ key: String, placeholder: String) -> String {
    let syms = shortcutModSymbols(mods).joined(separator: " ")
    let k = shortcutKeyLabel(key)
    if syms.isEmpty && k.isEmpty { return placeholder }
    if syms.isEmpty { return k }
    if k.isEmpty { return syms }
    return "\(syms) + \(k)"
}

/// A self-contained hotkey input: shows the current combo (⌘⌥⌃ + key) and a
/// record button that captures the next keystroke into the bindings. `onCapture`
/// fires after a successful capture (e.g. to auto-apply). Tears its monitor down
/// on disappear so a half-finished capture never outlives the view.
struct ShortcutRecorder: View {
    @Binding var mods: Set<String>
    @Binding var key: String
    var placeholder: String = "Record shortcut"
    var onCapture: () -> Void = {}

    @State private var capturing = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text(capturing ? "press keys..." : shortcutCombo(mods, key, placeholder: placeholder))
                .foregroundStyle((capturing || (mods.isEmpty && key.isEmpty)) ? .secondary : .primary)
                .font(.body.monospaced())
            Button {
                capturing ? stop() : start()
            } label: {
                Image(systemName: capturing ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(capturing ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help("Click, then press the shortcut (Esc cancels)")
        }
        .onDisappear { stop() }
    }

    private func start() {
        capturing = true
        monitor = ShortcutCapture.begin(onKey: { m, name in
            mods = m
            key = name
            stop()
            onCapture()
        }, onCancel: { stop() })
    }

    private func stop() {
        ShortcutCapture.end(monitor)
        monitor = nil
        capturing = false
    }
}
