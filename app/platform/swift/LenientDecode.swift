// Per-element tolerance for the row-editor blobs (`siteList`, `placementList`,
// `aliasList` -- each a JSON array persisted into ONE option string).
//
// A whole-array `try?` is the wrong shape for these: one element with a
// wrong-typed field makes the entire decode throw, the editor shows an empty
// list, and the user's first edit then persists that emptiness over every record
// that was fine. The value is hand-editable (`defaults write`) and has no undo,
// so the array must degrade one element at a time.
//
// The Lua readers of the same blobs already skip a bad row individually; this
// keeps both sides of each blob on one contract.

import Foundation

/// Decodes `T`, or nothing at all -- never throws, so it cannot fail its array.
struct LenientElement<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension Array where Element: Decodable {
    /// The stored array with unreadable elements dropped, or nil when the text is
    /// not a JSON array at all. nil vs `[]` is the distinction a caller needs to
    /// tell "nothing stored" from "stored something unreadable".
    static func decodeLeniently(fromJSON raw: String) -> [Element]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
              let wrapped = try? JSONDecoder().decode([LenientElement<Element>].self, from: data)
        else { return nil }
        return wrapped.compactMap(\.value)
    }
}
