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

/// The seed/persist DECISION CORE, lifted out of the view modifier below.
///
/// Split out because the two bugs this whole file exists to prevent are state
/// TRANSITIONS -- a seed counted as an edit, and an external clear echoed back
/// as `"[]"` -- and neither is reachable from a test while the machine lives in
/// a `ViewModifier`'s `@State`. As a plain value type it needs no SwiftUI host
/// and no rendering, so the transitions are asserted directly.
///
/// It decides ONLY. Reading the binding, writing the option, and reloading the
/// catalog stay with the modifier, which is why `Effect` names what to do rather
/// than doing it.
struct RowListMachine<Row: Equatable> {

    /// What the caller must do next. `.none` is the answer that matters: both
    /// historical bugs were an effect fired where `.none` belonged.
    enum Effect: Equatable {
        case none
        /// Put these rows in the binding -- a seed, or an external clear. Never
        /// persisted: writing here is what rewrote stored config on open.
        case setRows([Row])
        /// Persist these rows, then report a real edit.
        ///
        /// Named `persist`, not `write`: the seam's FileHandle guard matches on
        /// `.write(` and would otherwise flag every use of this case.
        case persist([Row])
    }

    private(set) var seeded = false

    /// What the last write stored -- initially what was decoded. Anything else
    /// in the rows is a real edit.
    ///
    /// Compared against decoded ROWS, never the raw `json` text: a decode can
    /// legitimately re-encode to a different string (SiteRow mints a missing id;
    /// a hand-edited value can differ in key order or whitespace), and comparing
    /// text would read that as an edit and rewrite the user's config the moment
    /// they opened the page.
    private(set) var persisted: [Row] = []

    /// The view appeared. Seeds once and only once -- a second call after a
    /// re-render must not re-decode, or a pending edit is silently reverted.
    mutating func appeared(json: String, decode: (String) -> [Row]) -> Effect {
        guard !seeded else { return .none }
        seeded = true
        persisted = decode(json)
        return .setRows(persisted)
    }

    /// The stored option changed underneath us. Only an EMPTY new value acts:
    /// the option was reset, so the list empties. `persisted` empties with it,
    /// so the row change this causes is not read back as an edit and does not
    /// write `"[]"` into the key that was just removed.
    mutating func jsonChanged(to new: String, rows: [Row]) -> Effect {
        guard new.isEmpty, !rows.isEmpty else { return .none }
        persisted = []
        return .setRows([])
    }

    /// The rows changed. Equal to what is persisted means this is the echo of a
    /// seed or a clear, not an edit -- the single guard both bugs came down to.
    mutating func rowsChanged(to new: [Row]) -> Effect {
        guard new != persisted else { return .none }
        persisted = new
        return .persist(new)
    }
}

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

    /// All three former `@State` fields, in one testable value. Every decision
    /// lives in `RowListMachine`; this modifier only routes events in and
    /// applies the effect that comes back.
    @State private var machine = RowListMachine<Row>()

    func body(content: Content) -> some View {
        content
            .onAppear { apply(machine.appeared(json: json, decode: decode)) }
            .onChange(of: json) { new in apply(machine.jsonChanged(to: new, rows: rows)) }
            .onChange(of: rows) { new in apply(machine.rowsChanged(to: new)) }
    }

    private func apply(_ effect: RowListMachine<Row>.Effect) {
        switch effect {
        case .none:
            break
        case .setRows(let new):
            // Deliberately no write: the machine has already recorded these as
            // persisted, so the row change this triggers comes back as `.none`.
            rows = new
        case .persist(let new):
            write(encode(new))
            onEdit()
        }
    }
}
