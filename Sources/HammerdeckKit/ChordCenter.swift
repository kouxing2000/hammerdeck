import Foundation

/// Chorded global shortcuts: a prefix hotkey (mods+key) arms a transient mode,
/// then a sequence of follow keys fires the action -- "cmd+shift+a, then b".
///
/// Built entirely on top of HotkeyCenter, so it needs NO new Carbon surface and
/// NO Accessibility permission: the prefix is an ordinary RegisterEventHotKey
/// hotkey, and each follow key is registered as a *bare* (modifier-less) hotkey
/// only for the brief window the chord is armed, then unregistered. While armed
/// the follow keys (and Escape) are swallowed system-wide; on a match, timeout,
/// or Escape, they are released and normal typing resumes.
///
/// Multiple chords may share one prefix (cmd+shift+a -> b, cmd+shift+a -> c):
/// the prefix is registered once and ref-counted, and arming walks the set of
/// follow sequences as a trie. A shorter sequence that is a prefix of a longer
/// one wins on its last key (first complete match fires) -- the registry's
/// conflict check refuses to bind such an ambiguous pair in the first place.
@MainActor
final class ChordCenter {
    static let shared = ChordCenter()
    private init() {}

    /// How long an armed chord waits for the next follow key before giving up.
    var timeout: TimeInterval = 1.5

    private struct Chord {
        let id: UInt32
        let follows: [String]      // ordered, lowercased follow-key names
        let handler: () -> Void
    }
    private struct Prefix: Hashable {
        let mods: [String]         // canonical (normalized, sorted, deduped)
        let key: String            // lowercased
    }

    private var nextId: UInt32 = 1
    private var chordById: [UInt32: (prefix: Prefix, chord: Chord)] = [:]
    private var idsByPrefix: [Prefix: Set<UInt32>] = [:]
    private var prefixUnbind: [Prefix: () -> Void] = [:]

    // Armed-session state (at most one prefix armed at a time).
    private var armedPrefix: Prefix?
    private var armedCandidates: [Chord] = []
    private var armedPos = 0
    private var armedUnbinds: [() -> Void] = []
    private var armedTimer: Timer?

    /// Register a chord. Returns its id, or nil if the prefix key or any follow
    /// key is unknown (or there are no follow keys -- that would be a plain
    /// hotkey, which callers should use instead).
    func bind(mods: [String], key: String, follows: [String],
              handler: @escaping () -> Void) -> UInt32? {
        guard !follows.isEmpty else { return nil }
        guard HotkeyCenter.keyCodes[key.lowercased()] != nil else { return nil }
        for f in follows {
            let lf = f.lowercased()
            // Unknown keys can't be registered; escape is reserved to cancel.
            guard HotkeyCenter.keyCodes[lf] != nil, lf != "escape", lf != "esc" else { return nil }
        }

        let prefix = Prefix(mods: Self.canonicalMods(mods), key: key.lowercased())
        let id = nextId; nextId += 1
        let chord = Chord(id: id, follows: follows.map { $0.lowercased() }, handler: handler)

        // Register the prefix hotkey once; later chords on the same prefix just
        // join the set. Bail (without consuming the id slot's side effects) if
        // the OS refuses the prefix registration.
        if idsByPrefix[prefix] == nil {
            guard let unbind = HotkeyCenter.shared.bind(
                mods: prefix.mods, key: prefix.key,
                handler: { ChordCenter.shared.arm(prefix) }) else { return nil }
            prefixUnbind[prefix] = unbind
            idsByPrefix[prefix] = []
        }
        idsByPrefix[prefix]?.insert(id)
        chordById[id] = (prefix, chord)
        return id
    }

    /// Unregister a chord. When the last chord on a prefix goes away, the prefix
    /// hotkey itself is unregistered; if that prefix is currently armed, disarm.
    func unbind(_ id: UInt32) {
        guard let entry = chordById.removeValue(forKey: id) else { return }
        let prefix = entry.prefix
        idsByPrefix[prefix]?.remove(id)
        // If this prefix is currently armed, the live session holds a by-value
        // snapshot of the candidates -- including this now-removed one, whose
        // handler closes over a Lua ref the caller is about to release. Disarm
        // so a follow-key press can't fire into a freed ref. (Re-press the
        // prefix to arm the survivors.) This covers BOTH the last-chord case
        // and rebinding/disabling one sibling mid-armed-window.
        if armedPrefix == prefix { disarm() }
        if idsByPrefix[prefix]?.isEmpty == true {
            idsByPrefix[prefix] = nil
            prefixUnbind[prefix]?()
            prefixUnbind[prefix] = nil
        }
    }

    // MARK: - Armed session

    private func arm(_ prefix: Prefix) {
        disarm()                                   // cancel any prior session
        let ids = idsByPrefix[prefix] ?? []
        armedPrefix = prefix
        armedCandidates = ids.compactMap { chordById[$0]?.chord }
        armedPos = 0
        registerLevel()
        startTimeout()
    }

    /// Register the distinct follow keys live at the current position, plus
    /// Escape (always cancels). Each fires advance(key)/disarm on the main loop.
    private func registerLevel() {
        var keys = Set<String>()
        for c in armedCandidates where armedPos < c.follows.count {
            keys.insert(c.follows[armedPos])
        }
        for k in keys {
            if let unbind = HotkeyCenter.shared.bind(mods: [], key: k,
                handler: { ChordCenter.shared.advance(k) }) {
                armedUnbinds.append(unbind)
            }
        }
        if let unbind = HotkeyCenter.shared.bind(mods: [], key: "escape",
            handler: { ChordCenter.shared.disarm() }) {
            armedUnbinds.append(unbind)
        }
    }

    private func advance(_ key: String) {
        armedTimer?.invalidate(); armedTimer = nil
        unregisterLevel()

        let matched = armedCandidates.filter { armedPos < $0.follows.count
            && $0.follows[armedPos] == key }
        guard !matched.isEmpty else { disarm(); return }

        let pos = armedPos + 1
        // First complete sequence wins (the registry forbids an ambiguous
        // shorter-prefix-of-longer pair, so at most one completes here).
        if let done = matched.first(where: { pos == $0.follows.count }) {
            let handler = done.handler
            disarm()
            handler()
            return
        }
        // Descend a level: keep the still-matching candidates and re-arm.
        armedCandidates = matched
        armedPos = pos
        registerLevel()
        startTimeout()
    }

    private func startTimeout() {
        let t = Timer(timeInterval: timeout, repeats: false) { _ in
            MainActor.assumeIsolated { ChordCenter.shared.disarm() }
        }
        RunLoop.main.add(t, forMode: .common)
        armedTimer = t
    }

    private func unregisterLevel() {
        for u in armedUnbinds { u() }
        armedUnbinds = []
    }

    private func disarm() {
        armedTimer?.invalidate(); armedTimer = nil
        unregisterLevel()
        armedPrefix = nil
        armedCandidates = []
        armedPos = 0
    }

    // MARK: - Helpers

    /// Normalize modifier names to canonical, deduped, sorted form so that the
    /// prefix of "shift+cmd" and "cmd+shift" hash to the same Prefix.
    static func canonicalMods(_ mods: [String]) -> [String] {
        var set = Set<String>()
        for m in mods {
            switch m.lowercased() {
            case "cmd", "command":  set.insert("cmd")
            case "alt", "option":   set.insert("alt")
            case "ctrl", "control": set.insert("ctrl")
            case "shift":           set.insert("shift")
            default: break
            }
        }
        return set.sorted()
    }

    // MARK: - Test introspection

    /// Whether a chord is currently armed (used by tests).
    var isArmed: Bool { armedPrefix != nil }
}
