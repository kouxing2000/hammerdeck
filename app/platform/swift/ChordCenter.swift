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
    var timeout: TimeInterval = 2.1

    private struct Chord {
        let id: UInt32
        let follows: [String]      // ordered, lowercased follow-key names
        let label: String          // action label, shown in the which-key hint
        let icon: String?          // action's SF Symbol name, the hint row's glyph
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
    private var armedDeadline: Date?   // when the current level times out (for the hint bar)

    // Which-key hint state. The hint shows after a short delay so an expert who
    // types the follow key immediately never sees it (no flicker); a hesitater
    // gets the menu. The panel instance is reused across arms.
    private var hintPanel: ChordHintPanel?
    private var hintTimer: Timer?
    private var hintShown = false
    /// Delay from arming to showing the hint. Under `timeout` so it's useful.
    var hintDelay: TimeInterval = 0.35

    /// Register a chord. Returns its id, or nil if the prefix key or any follow
    /// key is unknown (or there are no follow keys -- that would be a plain
    /// hotkey, which callers should use instead). `label` names the action in
    /// the which-key hint.
    func bind(mods: [String], key: String, follows: [String],
              label: String = "", icon: String? = nil, handler: @escaping () -> Void) -> UInt32? {
        guard !follows.isEmpty else { return nil }
        guard HotkeyCenter.keyCodes[key.lowercased()] != nil else { return nil }
        for f in follows {
            let lf = f.lowercased()
            // Unknown keys can't be registered; escape is reserved to cancel.
            guard HotkeyCenter.keyCodes[lf] != nil, lf != "escape", lf != "esc" else { return nil }
        }

        let prefix = Prefix(mods: Self.canonicalMods(mods), key: key.lowercased())
        let id = nextId; nextId += 1
        let chord = Chord(id: id, follows: follows.map { $0.lowercased() },
                          label: label, icon: icon, handler: handler)

        // Register the prefix hotkey once; later chords on the same prefix just
        // join the set. Bail (without consuming the id slot's side effects) if
        // the OS refuses the prefix registration.
        if idsByPrefix[prefix] == nil {
            guard let unbind = HotkeyCenter.shared.bind(
                mods: prefix.mods, key: prefix.key,
                handler: { ChordCenter.shared.prefixPressed(prefix) }) else { return nil }
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
        scheduleHint()
    }

    /// A press of a prefix combo. Normally (re-)arms the chord. BUT if that prefix
    /// is ALREADY armed and its own key is the next follow -- the "Hyper+M then M"
    /// case -- the user kept the leader (Hyper = a HELD combo) down, so this exact
    /// re-press IS the follow key: advance rather than reset. Without this, a chord
    /// whose follow equals its prefix key could never be typed leader-held (the
    /// second press just re-armed to the start). The sibling half -- a follow key
    /// DIFFERENT from the prefix key, pressed leader-held -- is the sticky twin in
    /// registerLevel().
    private func prefixPressed(_ prefix: Prefix) {
        if armedPrefix == prefix,
           armedCandidates.contains(where: {
               armedPos < $0.follows.count && $0.follows[armedPos] == prefix.key }) {
            advance(prefix.key)
            return
        }
        arm(prefix)
    }

    /// Register the distinct follow keys live at the current position, plus
    /// Escape (always cancels). Each fires advance(key)/disarm on the main loop.
    private func registerLevel() {
        var keys = Set<String>()
        for c in armedCandidates where armedPos < c.follows.count {
            keys.insert(c.follows[armedPos])
        }
        // The leader (e.g. Hyper = ⌘⌥⌃) is a HELD combo, so a user typing
        // "Hyper+M then C" naturally keeps Hyper down on the C. Bind each follow
        // key BARE *and* -- for keys other than the prefix key -- at the still-held
        // prefix mods (the "sticky twin", mirroring modal.lua's stickyMods), so the
        // chord fires whether or not the leader was released. The prefix KEY is
        // excepted: its sticky combo IS the prefix hotkey, so that same-key case is
        // handled in prefixPressed (advance vs re-arm). A sticky combo already
        // taken by a global just fails to register -- the bare key still works.
        let sticky = armedPrefix?.mods ?? []
        for k in keys {
            if let unbind = HotkeyCenter.shared.bind(mods: [], key: k,
                handler: { ChordCenter.shared.advance(k) }) {
                armedUnbinds.append(unbind)
            }
            if !sticky.isEmpty, k != armedPrefix?.key,
               let unbind = HotkeyCenter.shared.bind(mods: sticky, key: k,
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
        // If the hint is already up, update it to the new level immediately;
        // otherwise keep respecting the delay (an expert mid-sequence still
        // never sees it).
        if hintShown { presentHint() } else { scheduleHint() }
    }

    private func startTimeout() {
        let t = Timer(timeInterval: timeout, repeats: false) { _ in
            MainActor.assumeIsolated { ChordCenter.shared.disarm() }
        }
        RunLoop.main.add(t, forMode: .common)
        armedTimer = t
        armedDeadline = Date().addingTimeInterval(timeout)
    }

    private func unregisterLevel() {
        for u in armedUnbinds { u() }
        armedUnbinds = []
    }

    private func disarm() {
        armedTimer?.invalidate(); armedTimer = nil
        hintTimer?.invalidate(); hintTimer = nil
        if hintShown { hintPanel?.close(); hintShown = false }
        unregisterLevel()
        armedPrefix = nil
        armedCandidates = []
        armedPos = 0
    }

    // MARK: - Which-key hint

#if DEBUG
    /// Render the hint card with sample rows for a visual check (DebugControl
    /// `@chordhint`). Bypasses the real arm/event path -- pixels only.
    func debugPreviewHint() {
        if hintPanel == nil { hintPanel = ChordHintPanel() }
        let rows = [
            ChordHintPanel.Row(key: "w", label: "Window switcher", icon: "macwindow.on.rectangle"),
            ChordHintPanel.Row(key: "p", label: "Command palette", icon: "command"),
            ChordHintPanel.Row(key: "s", label: "Site switcher", icon: "bookmark"),
            ChordHintPanel.Row(key: "r", label: "Refresh wallpaper", icon: "photo.artframe"),
            ChordHintPanel.Row(key: "c", label: "more...", icon: "ellipsis"),
        ]
        hintPanel?.update(prefixMods: ["cmd", "shift"], prefixKey: "a", rows: rows,
                          remaining: timeout, total: timeout)
        hintShown = true
    }
#endif

    /// Show the hint after `hintDelay`, reading live state when it fires.
    private func scheduleHint() {
        hintTimer?.invalidate()
        let t = Timer(timeInterval: hintDelay, repeats: false) { _ in
            MainActor.assumeIsolated { ChordCenter.shared.presentHint() }
        }
        RunLoop.main.add(t, forMode: .common)
        hintTimer = t
    }

    /// Render (or refresh) the hint for the current level. No rows -> nothing.
    private func presentHint() {
        guard let prefix = armedPrefix else { return }
        let rows = hintRows()
        guard !rows.isEmpty else { return }
        if hintPanel == nil { hintPanel = ChordHintPanel() }
        // Remaining time on the current level so the bar depletes in step with
        // the real timeout (and ends exactly when it auto-disarms).
        let remaining = max(0, armedDeadline?.timeIntervalSinceNow ?? timeout)
        hintPanel?.update(prefixMods: prefix.mods, prefixKey: prefix.key, rows: rows,
                          remaining: remaining, total: timeout)
        hintShown = true
    }

    /// The distinct follow keys live at the current level, each labelled: a key
    /// that completes a chord here shows that action's label; a key that only
    /// descends deeper shows "more...". Sorted for a stable order.
    private func hintRows() -> [ChordHintPanel.Row] {
        var byKey: [String: [Chord]] = [:]
        for c in armedCandidates where armedPos < c.follows.count {
            byKey[c.follows[armedPos], default: []].append(c)
        }
        return byKey.keys.sorted().map { k in
            let cs = byKey[k]!
            if let done = cs.first(where: { armedPos + 1 == $0.follows.count }) {
                // Terminal key: the action's own glyph (nil -> a neutral dot, so
                // the icon column never goes ragged within the card).
                return ChordHintPanel.Row(key: k, label: done.label.isEmpty ? "(action)" : done.label,
                                          icon: done.icon)
            }
            // Branch key: more follow-keys lie below it -- a continuation glyph.
            return ChordHintPanel.Row(key: k, label: "more...", icon: "ellipsis")
        }
    }

    // MARK: - Helpers

    /// Normalize modifier names to canonical, deduped, sorted form so that the
    /// prefix of "shift+cmd" and "cmd+shift" hash to the same Prefix.
    /// Unknown names are skipped here, but never arrive: bind_chord rejects
    /// them at the seam (KeyModifier.firstUnknown).
    static func canonicalMods(_ mods: [String]) -> [String] {
        var set = Set<String>()
        for m in mods {
            if let mod = KeyModifier.parse(m) { set.insert(mod.canonical) }
        }
        return set.sorted()
    }

    // MARK: - Test introspection

    /// Whether a chord is currently armed (used by tests).
    var isArmed: Bool { armedPrefix != nil }
}
