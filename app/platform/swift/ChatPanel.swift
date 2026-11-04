// Panels.swift split: one self-owned native UI surface (see Panels.swift
// for the shared FloatingPanel base and the rationale for our own panels).

import AppKit
import SwiftUI

// MARK: - Chat (a floating conversation: bubbles above, an input line below)

/// One turn of a ChatPanel conversation.
struct ChatTurn: Identifiable {
    enum Role: String { case user, assistant, note }
    let id: Int
    let role: Role
    let text: String
}

@MainActor
private final class ChatModel: ObservableObject {
    static let typingID = -1
    @Published var turns: [ChatTurn] = []
    @Published var busy = false
    /// Bumped on every update, so the transcript scrolls to its end even when a
    /// turn is replaced rather than added.
    @Published var revision = 0
}

/// A floating chat window: the conversation as bubbles (SwiftUI), the user's
/// turns on the right and replies on the left, above an input line and a send
/// button (AppKit -- the same keyable-without-activating field AskTextPanel uses,
/// so typing focus, Enter and Escape behave as they do there). Enter or the send
/// button hands non-blank text to `onSend` and clears the field; the window stays.
/// While a reply is on its way (`busy`) sending is off and the text stays in the
/// field, so turns cannot arrive out of order. Escape (wherever the focus is) or
/// the close button calls `onClose` once. The window opens at the right of the
/// screen under the pointer, beside the text it is about, and drags by its
/// background.
@MainActor
final class ChatPanel: NSObject, NSTextFieldDelegate {
    /// Escape closes the window wherever the focus is. It is caught here, before
    /// dispatch, because a bubble clicked to select text takes the focus and
    /// swallows Escape itself. The one exception is text still being composed in
    /// an input method (pinyin, kana): there Escape cancels the composition.
    private final class Window: FloatingPanel {
        var onEscape: (() -> Void)?
        override func sendEvent(_ event: NSEvent) {
            if event.type == .keyDown, event.keyCode == 53,
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               !((firstResponder as? NSTextView)?.hasMarkedText() ?? false) {
                onEscape?()
                return
            }
            super.sendEvent(event)
        }
    }

    private let panel: Window
    private let model = ChatModel()
    private let field = NSTextField()
    private let send: NSButton
    private let onSend: (String) -> Void
    private let onClose: () -> Void
    private var done = false

    init(title: String, placeholder: String,
         onSend: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.onSend = onSend
        self.onClose = onClose
        let width: CGFloat = 480
        let height: CGFloat = 540
        let headerHeight: CGFloat = 40
        let inputHeight: CGFloat = 52
        let sendTitle = Strings.t("chat.send", default: "Send")
        send = NSButton(image: NSImage(systemSymbolName: "arrow.up.circle.fill",
                                       accessibilityDescription: sendTitle) ?? NSImage(),
                        target: nil, action: nil)
        panel = Window(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                       level: .floating,
                       collectionBehavior: [.canJoinAllSpaces, .transient],
                       keyable: true, mouseTransparent: false)
        super.init()

        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.onEscape = { [weak self] in self?.finish() }

        let content = NSVisualEffectView()
        content.material = .menu
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 14
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let head = NSTextField(labelWithString: title)
        head.font = .boldSystemFont(ofSize: 14)
        head.frame = NSRect(x: 16, y: height - 28, width: width - 64, height: 18)
        content.addSubview(head)

        let closeTitle = Strings.t("chat.close", default: "Close")
        let close = NSButton(image: NSImage(systemSymbolName: "xmark",
                                            accessibilityDescription: closeTitle) ?? NSImage(),
                             target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = closeTitle
        close.frame = NSRect(x: width - 36, y: height - 31, width: 22, height: 22)
        content.addSubview(close)

        let transcript = NSHostingView(rootView: ChatTranscript(
            model: model, copyLabel: Strings.t("chat.copy", default: "Copy")))
        // A fixed frame: the window keeps its size whatever the transcript holds.
        transcript.sizingOptions = []
        transcript.frame = NSRect(x: 0, y: inputHeight, width: width,
                                  height: height - headerHeight - inputHeight)
        content.addSubview(transcript)

        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 14)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.frame = NSRect(x: 14, y: 13, width: width - 64, height: 26)
        content.addSubview(field)

        send.target = self
        send.action = #selector(sendClicked)
        send.isBordered = false
        send.imageScaling = .scaleProportionallyUpOrDown
        send.contentTintColor = .controlAccentColor
        send.toolTip = sendTitle
        send.frame = NSRect(x: width - 42, y: 12, width: 28, height: 28)
        content.addSubview(send)

        panel.contentView = content
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.maxX - width - 24,
                                         y: area.midY - height / 2))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// The window itself, for tests that drive it with events.
    var window: NSWindow { panel }

    /// Replace the conversation; `busy` shows a typing bubble after the last turn.
    func setTurns(_ turns: [ChatTurn], busy: Bool) {
        model.turns = turns
        model.busy = busy
        model.revision += 1
        send.isEnabled = !busy
    }

    /// Silent close (stop semantics): no callback.
    func close() {
        done = true
        panel.orderOut(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submit(); return true
        default:
            // Escape never closes from here: the window catches it first, and one
            // reaching the field is an input method's, cancelling a composition.
            return false
        }
    }

    @objc private func sendClicked() { submit() }
    @objc private func closeClicked() { finish() }

    private func submit() {
        let text = field.stringValue
        guard !done, !model.busy,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        field.stringValue = ""
        onSend(text)
    }

    private func finish() {
        guard !done else { return }
        done = true
        panel.orderOut(nil)
        onClose()
    }
}

// MARK: - Transcript (SwiftUI)

private struct ChatTranscript: View {
    @ObservedObject var model: ChatModel
    let copyLabel: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.turns) { turn in
                        ChatBubble(turn: turn, copyLabel: copyLabel).id(turn.id)
                    }
                    if model.busy {
                        TypingBubble().id(ChatModel.typingID)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onAppear { scrollToEnd(proxy) }
            .onChange(of: model.revision) { _ in
                withAnimation(.easeOut(duration: 0.15)) { scrollToEnd(proxy) }
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if model.busy {
            proxy.scrollTo(ChatModel.typingID, anchor: .bottom)
        } else if let last = model.turns.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

private struct ChatBubble: View {
    let turn: ChatTurn
    let copyLabel: String

    var body: some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 56)
                Text(turn.text)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case .assistant:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.markdown(turn.text))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(turn.text, forType: .string)
                    } label: {
                        Label(copyLabel, systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.leading, 8)
                }
                Spacer(minLength: 56)
            }
        case .note:
            Text(turn.text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Inline markdown (bold, italics, code, links), keeping the reply's own line
    /// breaks; text that does not parse shows as written.
    private static func markdown(_ text: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: opts)) ?? AttributedString(text)
    }
}

private struct TypingBubble: View {
    var body: some View {
        Text("•••")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
