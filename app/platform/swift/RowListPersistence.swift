// The seed/persist state machine behind every row-editor option (`siteList`,
// `placementList`, `aliasList` -- each a list of rows persisted as a JSON array in
// ONE option string).
//
// Extracted because all three editors carried their own copy of the same three
// @State fields and three hooks, in three subtly different versions -- and this
// dance is where their bugs have been: decoding counted as an edit and rewrote
// stored config on open, and an externally emptied value round-tripped "[]" back
// into defaults.
//
// It owns the state machine ONLY. Layout, add/remove buttons, and the reload
// timing stay with each editor.

import SwiftUI

extension View {
    /// Seeds `rows` from `json` once, clears them when `json` empties, and writes
    /// `encode(rows)` on any change that is not the seed.
    ///
    /// A structural edit that must be visible to a catalog reload writes
    /// explicitly and reloads, rather than waiting for the change hook here -- the
    /// hook runs after the view update, which is too late to order a reload
    /// against. This writes the same value again afterwards, harmlessly.
    /// `onEdit` runs only when a real edit was written -- never for the seed. A
    /// caller that tracks "stored but not re-registered yet" needs exactly that
    /// distinction, and the guard below is the only place that knows it.
    func rowListPersistence<Row: Equatable>(
        json: String,
        rows: Binding<[Row]>,
        decode: @escaping (String) -> [Row],
        encode: @escaping ([Row]) -> String,
        write: @escaping (String) -> Void,
        onEdit: @escaping () -> Void = {}
    ) -> some View {
        modifier(RowListPersistence(json: json, rows: rows, decode: decode,
                                    encode: encode, write: write, onEdit: onEdit))
    }
}

private struct RowListPersistence<Row: Equatable>: ViewModifier {
    let json: String
    @Binding var rows: [Row]
    let decode: (String) -> [Row]
    let encode: ([Row]) -> String
    let write: (String) -> Void
    let onEdit: () -> Void

    @State private var seeded = false
    /// What the last write stored -- initially what was decoded. Anything else in
    /// `rows` is a real edit.
    ///
    /// This is compared against the decoded ROWS, never against the raw `json`
    /// text: a decode can legitimately produce something that re-encodes to a
    /// different string (SiteRow mints a missing id; any hand-edited value can
    /// differ in key order or whitespace), and comparing text would read that as
    /// an edit and rewrite the user's config the moment they opened the page.
    @State private var persisted: [Row] = []

    func body(content: Content) -> some View {
        content
            .onAppear {
                if !seeded { rows = decode(json); persisted = rows; seeded = true }
            }
            .onChange(of: json) { new in
                // An external clear (the option was reset) empties the list --
                // and marks it persisted, so the change hook below does not turn
                // around and write "[]" back into a key that was just removed.
                if new.isEmpty && !rows.isEmpty { rows = []; persisted = [] }
            }
            .onChange(of: rows) { new in
                guard new != persisted else { return }   // seeding is not an edit
                persisted = new
                write(encode(new))
                onEdit()
            }
    }
}
