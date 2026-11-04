import AppKit
import SwiftUI
import XCTest
@testable import HammerdeckKit

// The chat window's keyboard contract, driven with events sent straight to the
// window (no CGEvent: nothing reaches other apps, the pointer does not move).
// The panel is shown and takes key focus for a moment, hence the UI-test gate.
@MainActor
final class ChatPanelTests: XCTestCase {

    private var sent: [String] = []
    private var closes = 0

    private func show() throws -> ChatPanel {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HAMMERDECK_UI_TESTS"] == "1",
            "shows a real panel -- set HAMMERDECK_UI_TESTS=1 to run")
        let chat = ChatPanel(title: "AI: Summary", placeholder: "Ask a follow-up",
                             onSend: { [unowned self] in self.sent.append($0) },
                             onClose: { [unowned self] in self.closes += 1 })
        chat.setTurns([ChatTurn(id: 0, role: .user, text: "the selection"),
                       ChatTurn(id: 1, role: .assistant, text: "a **reply**")], busy: false)
        settle()
        addTeardownBlock { chat.close() }
        return chat
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }

    private func field(_ chat: ChatPanel) throws -> NSTextField {
        try XCTUnwrap(chat.window.contentView?.subviews.compactMap { $0 as? NSTextField }
            .first { $0.isEditable }, "the input field")
    }

    private func key(_ chat: ChatPanel, code: UInt16, chars: String,
                     modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: chat.window.windowNumber, context: nil,
                                     characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code)!
        chat.window.sendEvent(event)
    }

    func testEnterSendsTextAndKeepsTheWindowOpen() throws {
        let chat = try show()
        let input = try field(chat)
        input.stringValue = "why?"
        key(chat, code: 36, chars: "\r")
        XCTAssertEqual(sent, ["why?"])
        XCTAssertEqual(input.stringValue, "", "the field clears for the next question")
        XCTAssertTrue(chat.window.isVisible)
        input.stringValue = "   "
        key(chat, code: 36, chars: "\r")
        XCTAssertEqual(sent, ["why?"], "a blank Enter sends nothing")
        XCTAssertEqual(closes, 0)
    }

    /// While a reply is on its way the next question stays in the field.
    func testEnterWhileBusyKeepsTheQuestion() throws {
        let chat = try show()
        chat.setTurns([ChatTurn(id: 0, role: .user, text: "the selection")], busy: true)
        let input = try field(chat)
        input.stringValue = "next"
        key(chat, code: 36, chars: "\r")
        XCTAssertEqual(sent, [])
        XCTAssertEqual(input.stringValue, "next")
    }

    func testEscapeWithAModifierDoesNotClose() throws {
        let chat = try show()
        key(chat, code: 53, chars: "\u{1b}", modifiers: .command)
        XCTAssertEqual(closes, 0)
        XCTAssertTrue(chat.window.isVisible)
    }

    func testEscapeInTheFieldClosesOnce() throws {
        let chat = try show()
        key(chat, code: 53, chars: "\u{1b}")
        XCTAssertEqual(closes, 1)
        XCTAssertFalse(chat.window.isVisible)
        key(chat, code: 53, chars: "\u{1b}")
        XCTAssertEqual(closes, 1, "a second Escape reports nothing")
    }

    /// A view that takes the focus and swallows every key, as a bubble clicked
    /// to select text does with Escape.
    private final class KeyEater: NSView {
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {}
        override func cancelOperation(_ sender: Any?) {}
    }

    /// Escape closes the window whatever the focused view does with the key.
    func testEscapeClosesEvenWhenTheFocusedViewSwallowsIt() throws {
        let chat = try show()
        let eater = KeyEater(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        chat.window.contentView?.addSubview(eater)
        chat.window.makeFirstResponder(eater)
        XCTAssertTrue(chat.window.firstResponder === eater, "precondition: focus left the field")
        key(chat, code: 53, chars: "\u{1b}")
        XCTAssertEqual(closes, 1)
    }

    /// While an input method is composing (pinyin, kana), Escape cancels the
    /// composition and the window stays.
    func testEscapeDuringInputMethodCompositionKeepsTheWindow() throws {
        let chat = try show()
        let input = try field(chat)
        chat.window.makeFirstResponder(input)
        let editor = try XCTUnwrap(chat.window.firstResponder as? NSTextView, "the field editor")
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText(), "precondition: composing")
        key(chat, code: 53, chars: "\u{1b}")
        XCTAssertEqual(closes, 0)
        XCTAssertTrue(chat.window.isVisible)
    }

    func testStopClosesSilently() throws {
        let chat = try show()
        chat.close()
        XCTAssertFalse(chat.window.isVisible)
        XCTAssertEqual(closes, 0, "stop is not the user closing it")
    }
}
