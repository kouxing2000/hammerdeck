// The DATA the config UI moves between the Lua registry and SwiftUI: the DTOs
// decoded from Lua tables (OptionInfo, TriggerSpec, ActionInfo, FeatureInfo,
// RuleInfo, ...) plus the dictionary accessors their decoders are written in
// terms of.
//
// Split out of SettingsStore.swift (CODE-19, 2026-07-24): these are inert value
// types with no state, no observation and no behavior, and they made up ~40% of
// a 1100-line file whose actual job is the ObservableObject below. Pure code
// movement -- SettingsStore remains the ONE ObservableObject (a real split into
// several stores stays rejected; `features` + selection cross-cut ~12 consumer
// views, so it would force nested-ObservableObject forwarding and silent
// UI-staleness).

import Foundation

// MARK: - Lua-bridged dictionary accessors
//
// Lua tables cross the bridge as [String: Any] (numbers always as Double -- see
// LuaState.any). These fold the repeated `dict["k"] as? T ?? default` reads in
// the init?(_ dict:) decoders below into one named, type-correct accessor each,
// so a decoder reads as a field list rather than a wall of casts.
extension Dictionary where Key == String, Value == Any {
    /// String field, or `def` (default "") when absent / not a string.
    func str(_ key: String, _ def: String = "") -> String { self[key] as? String ?? def }
    /// Optional string field (nil when absent) -- for genuinely optional fields.
    func strOpt(_ key: String) -> String? { self[key] as? String }
    /// Bool field, or `def` (default false) when absent / not a bool.
    func bool(_ key: String, _ def: Bool = false) -> Bool { self[key] as? Bool ?? def }
    /// Optional Double field (nil when absent / not a number).
    func doubleOpt(_ key: String) -> Double? { self[key] as? Double }
    /// Optional Int field, decoded from a Lua number (which bridges as Double).
    func intOpt(_ key: String) -> Int? { (self[key] as? Double).map(Int.init) }
    /// Lua array-of-strings, dropping non-string entries; [] when absent.
    func strArray(_ key: String) -> [String] {
        (self[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }
}

struct OptionInfo: Identifiable {
    let key: String
    let type: String        // bool | int | string | enum | time | appList | secret
    let label: String
    let defaultValue: Any?
    let min: Double?
    let max: Double?
    let values: [String]
    let labels: [String]    // enum display labels, parallel to `values` (may be empty)
    let multiline: Bool     // string: render a multi-line text box (one item per line)
    let defaultLabel: String // appList: name shown for the empty/"default app" choice
    let hint: String        // optional one-line caption rendered under the control
    let section: String     // optional group header; options sharing one render together
    let actionLabel: String // optional: render a button (calls the feature's optionAction)
    let preview: String     // optional token -> a small animated preview on the row (e.g. "case:upper")
    let validate: String?   // secret: provider name -> Settings renders a Validate button
    let gatedBy: String?    // option key whose validation gates this control (grayed until validated)
    let valuesFrom: String? // enum: option key whose validation supplies dynamic choices
    let collapsible: Bool   // render the editor inside a collapsed disclosure (keeps tall controls tidy)
    var id: String { key }

    init?(_ dict: [String: Any]) {
        guard let key = dict["key"] as? String, let type = dict["type"] as? String else { return nil }
        self.key = key
        self.type = type
        self.label = dict.str("label", key)
        self.defaultValue = dict["default"]
        self.min = dict.doubleOpt("min")
        self.max = dict.doubleOpt("max")
        self.values = dict.strArray("values")
        self.labels = dict.strArray("labels")
        self.multiline = dict.bool("multiline")
        self.defaultLabel = dict.str("defaultLabel")
        self.hint = dict.str("hint")
        self.section = dict.str("section")
        self.actionLabel = dict.str("actionLabel")
        self.preview = dict.str("preview")
        self.validate = dict.strOpt("validate")
        self.gatedBy = dict.strOpt("gatedBy")
        self.valuesFrom = dict.strOpt("valuesFrom")
        self.collapsible = dict.bool("collapsible")
    }

    /// The display label for an enum value -- the parallel `labels` entry when
    /// one exists, else the raw value (so "newlinesToCommas" never leaks into
    /// a picker once labels are declared).
    func enumLabel(_ value: String) -> String {
        if let i = values.firstIndex(of: value), i < labels.count { return labels[i] }
        return value
    }
}

// A trigger spec, mirroring the Lua trigger shape. Round-trips through the
// registry: parsed from describe(), emitted as a Lua literal for setTrigger.
struct TriggerSpec: Equatable {
    var type: String          // hotkey | chord | schedule | event
    var mods: [String]        // hotkey / chord (prefix)
    var key: String           // hotkey / chord (prefix)
    var follows: [String]     // chord (ordered follow-key sequence)
    var everyMin: Int?        // schedule (interval)
    var at: String?           // schedule (daily HH:MM)
    var event: String?        // event

    init(type: String = "hotkey", mods: [String] = [], key: String = "",
         follows: [String] = [],
         everyMin: Int? = nil, at: String? = nil, event: String? = nil) {
        self.type = type; self.mods = mods; self.key = key; self.follows = follows
        self.everyMin = everyMin; self.at = at; self.event = event
    }

    init?(_ dict: [String: Any]?) {
        guard let dict, let type = dict["type"] as? String else { return nil }
        self.type = type
        self.mods = dict.strArray("mods")
        self.key = dict.str("key")
        self.follows = dict.strArray("follows")
        self.everyMin = dict.intOpt("everyMin")
        self.at = dict.strOpt("at")
        self.event = dict.strOpt("event")
    }

    /// Marshal as a Lua call argument (a real table value, not source) for
    /// registry.setTrigger / triggers.* -- so a hand-typed key can't break or
    /// inject into a chunk; there is no source to escape.
    var luaArg: LuaArg {
        func list(_ xs: [String]) -> LuaArg { .array(xs.map(LuaArg.string)) }
        switch type {
        case "hotkey":
            return .table(["type": .string("hotkey"), "mods": list(mods), "key": .string(key)])
        case "chord":
            return .table(["type": .string("chord"), "mods": list(mods),
                           "key": .string(key), "follows": list(follows)])
        case "schedule":
            if let everyMin { return .table(["type": .string("schedule"), "everyMin": .int(everyMin)]) }
            return .table(["type": .string("schedule"), "at": .string(at ?? "00:00")])
        case "event":
            return .table(["type": .string("event"), "event": .string(event ?? "wake")])
        default:
            return .table([:])
        }
    }
}

extension TriggerSpec {
    /// Canonical modifier order for a persisted hotkey/chord spec, so the SAME
    /// keystroke yields the SAME mods[] no matter which editor built it (the
    /// Settings TriggerEditor vs the Shortcut Map row). Keyboard order,
    /// outermost-to-innermost on a Mac: ⇧⌃⌥⌘. (triggers.encode also canonicalizes
    /// mod order on the Lua side, so this is belt-and-suspenders -- but it keeps
    /// the two Swift surfaces from emitting visibly-different mods[] for one combo.)
    static let modOrder = ["shift", "ctrl", "alt", "cmd"]

    /// Parse a chord follow-key field (space/comma separated) into a lowercased
    /// key list -- the one parser both editors share.
    static func parseFollows(_ field: String) -> [String] {
        field.split(whereSeparator: { $0 == " " || $0 == "," }).map { $0.lowercased() }
    }

    /// Build a hotkey/chord spec from an editor's live modifier set, key field,
    /// and follow-key field: modifiers in canonical order, the key trimmed +
    /// lowercased, and a non-empty follows field promoting it to a chord. The
    /// single home for "keystroke editor fields -> a TriggerSpec", so the
    /// TriggerEditor and the Shortcut Map can't drift on modifier order or key
    /// casing (they did: cmd,alt,ctrl,shift vs shift,ctrl,alt,cmd, and one
    /// lowercased the key while the other didn't).
    static func keyish(mods: Set<String>, key: String, follows: String) -> TriggerSpec {
        let ordered = modOrder.filter { mods.contains($0) }
        let k = key.trimmingCharacters(in: .whitespaces).lowercased()
        let followKeys = parseFollows(follows)
        if followKeys.isEmpty {
            return TriggerSpec(type: "hotkey", mods: ordered, key: k)
        }
        return TriggerSpec(type: "chord", mods: ordered, key: k, follows: followKeys)
    }
}

// One named, independently triggerable entry point of a feature (a plugin may
// declare several -- each gets its own trigger editor).
struct ActionInfo: Identifiable {
    let id: String
    let label: String
    let description: String             // optional one-line "what this action does"
    let mnemonic: String                // optional "why this key" hint for the DEFAULT
    let trigger: TriggerSpec?           // current (override or default)
    let defaultTrigger: TriggerSpec?    // declared default (may be nil)
    let triggerOverridden: Bool
    let triggerDesc: String
    // May this action be driven by an AUTOMATED trigger (schedule / system
    // event), not just a manual one (hotkey / chord)? False for context-
    // dependent actions -- the trigger picker hides the automated types for them.
    let automatable: Bool
    // Optional per-action SF Symbol name; nil falls back to the feature glyph.
    // The command palette and the menubar submenu render it as the row's icon.
    let icon: String?
    // Created + bound by an option editor (e.g. a Saved-placements snap with its
    // inline shortcut), so the detail view hides it from the generic per-action
    // trigger sections -- otherwise it appears twice.
    let dynamic: Bool

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        self.label = dict.str("label", id)
        self.description = dict.str("description")
        self.mnemonic = dict.str("mnemonic")
        self.trigger = TriggerSpec(dict["trigger"] as? [String: Any])
        self.defaultTrigger = TriggerSpec(dict["defaultTrigger"] as? [String: Any])
        self.triggerOverridden = dict.bool("triggerOverridden")
        self.triggerDesc = dict.str("triggerDesc")
        self.automatable = dict.bool("automatable")
        self.icon = (dict["icon"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.dynamic = dict.bool("dynamic")
    }
}

// One entry of a feature's self-reported schedule (its internal timers/events
// made visible to the Automation Timeline). A service's `schedule(ctx)`
// descriptor produces these; describe() normalizes them. `kind` is exactly one
// of everyMin / at / event / note, so the Timeline can route each to the ruler,
// a repeating lane, or the events/conditions column. `optionKey`, when present,
// names the feature option the Timeline edits to change this entry.
struct ScheduleEntry: Identifiable {
    let label: String
    let kind: String        // everyMin | at | event | note
    let everyMin: Int?
    let at: String?         // HH:MM
    let event: String?
    let note: String?
    let optionKey: String?
    let category: String
    let id = UUID()

    init?(_ dict: [String: Any]) {
        guard let label = dict["label"] as? String, let kind = dict["kind"] as? String else { return nil }
        self.label = label
        self.kind = kind
        self.everyMin = dict.intOpt("everyMin")
        self.at = dict.strOpt("at")
        self.event = dict.strOpt("event")
        self.note = dict.strOpt("note")
        self.optionKey = dict.strOpt("optionKey")
        self.category = dict.str("category", "general")
    }

    /// Minutes-since-midnight for an `at` entry; nil for non-time entries.
    var minutesOfDay: Int? {
        guard kind == "at", let at else { return nil }
        return HHMM.minutesOfDay(at)
    }
}

/// A feature-contributed native PAGE: the manifest's `page = {title, icon}`
/// declaration. The feature names the page (title + SF Symbol); the actual
/// SwiftUI view is supplied host-side by FeaturePageRegistry, keyed by feature
/// id. This is what makes a native UI "plug in" -- the sidebar is driven by these
/// declarations, with no central enum/switch to edit per page.
struct PageInfo {
    let title: String
    let icon: String

    init?(_ dict: [String: Any]?) {
        guard let dict, let title = dict["title"] as? String, !title.isEmpty else { return nil }
        self.title = title
        self.icon = dict.str("icon", "doc")
    }
}

struct FeatureInfo: Identifiable {
    let id: String
    let name: String
    let description: String
    let category: String        // domain tag (text/windows/web/...), shown as a small label
    let icon: String?           // per-feature SF Symbol; nil -> fall back to the category glyph
    let context: String         // WHEN it applies -- the primary grouping axis (FeatureContext)
    let requires: [String]      // OS preconditions, e.g. ["accessibility"]
    let recommended: Bool       // part of the curated "Essentials" starter set
    let preference: Bool        // a global behavior toggle -> shown in General > Behavior, hidden from the catalog
    let version: String
    let kind: String        // action | service
    var enabled: Bool
    let triggerDesc: String
    let options: [OptionInfo]
    let failed: Bool            // load or start error -- the feature is broken
    let errorMessage: String
    let actions: [ActionInfo]   // one trigger editor per entry; empty for pure services
    let schedule: [ScheduleEntry]   // self-reported internal schedule (Timeline); may be empty
    let page: PageInfo?         // a contributed native Homepage page, if declared

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.description = dict.str("description")
        self.category = dict.str("category", "general")
        self.icon = (dict["icon"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.context = dict.str("context", "anywhere")
        self.requires = dict.strArray("requires")
        self.recommended = dict.bool("recommended")
        self.preference = dict.bool("preference")
        self.version = dict.str("version")
        self.kind = dict.str("kind", "action")
        self.enabled = dict.bool("enabled")
        self.triggerDesc = dict.str("triggerDesc")
        self.options = (dict["options"] as? [Any])?
            .compactMap { $0 as? [String: Any] }
            .compactMap(OptionInfo.init) ?? []
        self.failed = dict.bool("failed")
        self.errorMessage = dict.str("error")
        self.actions = (dict["actions"] as? [Any])?
            .compactMap { $0 as? [String: Any] }
            .compactMap(ActionInfo.init) ?? []
        self.schedule = (dict["schedule"] as? [Any])?
            .compactMap { $0 as? [String: Any] }
            .compactMap(ScheduleEntry.init) ?? []
        self.page = PageInfo(dict["page"] as? [String: Any])
    }
}

/// Live state of a `validate`-able secret (e.g. an OpenAI key): the transient UI
/// status shown next to the Validate button. The DURABLE "is it validated" bit
/// lives in UserDefaults (feature state, so the Lua feature reads it too) -- this
/// is just the in-session spinner/result for the editor.
enum ValidationState: Equatable {
    case idle
    case validating
    case ok(String)
    case failed(String)
}

// MARK: - Automation rules (the Rules page)

/// One row of the Rules list -- the serializable shape rules.describe() emits.
struct RuleInfo: Identifiable {
    let id: String
    let name: String             // the user's label (blank if unnamed -> fall back to triggerDesc)
    let enabled: Bool
    let sentence: String         // engine read-back ("When Safari loses focus, minimize it."),
                                 // "" if the grammar can't phrase it -- an unnamed rule lists as
                                 // this (matching the editor's Name placeholder)
    let triggerDesc: String      // "state: frontmostApp becomes Safari", "event: wake", ...
    let effectDesc: String       // 'Notify "Safari is front"', "Run bing_daily.refresh"
    let on: [String: Any]        // raw trigger spec -- pre-fills the edit form
    let effect: [String: Any]    // raw effect node -- pre-fills the edit form
    // A "from the trigger" effect reacts to its trigger -- it can't be fired in
    // isolation (no live context), so the Test button hides for it.
    let contextBound: Bool
    // A rule whose target (feature/signal) is absent THIS boot: PRESERVED on disk
    // (never silently deleted) and shown greyed with the reason. It re-activates
    // when the target returns, or the user fixes its JSON / deletes it.
    let unavailable: Bool
    let unavailableReason: String
    // Fire status (this session): when it last fired, whether that was a Test, and
    // whether the effect succeeded. nil lastFired = not fired yet. Lets the list
    // surface a silently-dead rule ("not fired yet") at a glance.
    let lastFired: Date?
    let lastFiredTest: Bool
    let lastFiredOk: Bool

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        self.name = dict.str("name")
        self.enabled = dict.bool("enabled", true)
        self.sentence = dict.str("sentence")
        self.triggerDesc = dict.str("triggerDesc")
        self.effectDesc = dict.str("effectDesc")
        self.on = dict["on"] as? [String: Any] ?? [:]
        self.effect = dict["effect"] as? [String: Any] ?? [:]
        self.contextBound = dict.bool("contextBound")
        self.unavailable = dict.bool("unavailable")
        self.unavailableReason = dict.str("reason")
        if let t = dict["lastFired"] as? Double { self.lastFired = Date(timeIntervalSince1970: t) }
        else if let t = dict["lastFired"] as? Int { self.lastFired = Date(timeIntervalSince1970: Double(t)) }
        else { self.lastFired = nil }
        self.lastFiredTest = dict.bool("lastFiredTest")
        self.lastFiredOk = dict.bool("lastFiredOk", true)
    }
}

/// One selectable effect for the Add-rule form's "Do" dropdown (effects.catalog).
struct RuleEffectOption: Identifiable, Hashable {
    let kind: String             // notify | layout | runShortcut | openURL | lockScreen | chain | command
    let label: String
    let feature: String?
    let action: String?
    var id: String { kind == "command" ? "command:\(feature ?? "").\(action ?? "")" : kind }

    init?(_ dict: [String: Any]) {
        guard let kind = dict["kind"] as? String else { return nil }
        self.kind = kind
        self.label = dict.str("label", kind)
        self.feature = dict.strOpt("feature")
        self.action = dict.strOpt("action")
    }
}

/// One named snap position for the layout editor's position picker (id + label,
/// from windows.POSITION_ORDER / POSITION_LABELS).
struct LayoutPosition: Identifiable, Hashable {
    let id: String
    let label: String
}

/// UI metadata for a state signal (from signals.lua's `meta`) -- lets the Rules
/// form render any signal (label, value noun, transition verbs) with no per-signal
/// Swift code, so a new signal needs zero view changes.
struct SignalMeta {
    let label: String
    let valueLabel: String
    let enterVerb: String
    let leaveVerb: String
    let example: String
    // The trigger-context key this signal publishes ("display" | "app"), or nil for
    // an enum signal that publishes nothing bindable. Drives the from-trigger option.
    let provides: String?
    // The TIMING subtitle for each edge ("the moment you click away"), shown under
    // the verb in the token verb-popover. Optional -- nil = no subtitle.
    let enterWhen: String?
    let leaveWhen: String?
    // Whether this signal matches a rule by a stored bundle id (the app-identity
    // signals: frontmostApp, runningApps). Drives the installed-apps app picker +
    // the `on.bundleId` persistence -- a capability from the signal, NOT a hardcoded
    // signal name (mirrors the engine's sig.bundleIdMatch gate in rules.bindOne).
    let bundleIdMatch: Bool
    // Whether the matched entity is GONE on the LEAVE edge (runningApps quits,
    // displaysPresent disconnects) -- so a from-trigger effect that acts on it would
    // always fail. Drives the leave-edge footgun warning. False for frontmostApp
    // ("loses focus" keeps the app alive).
    let goneOnLeave: Bool

    init(_ d: [String: Any]) {
        label = d.str("label")
        valueLabel = d.str("valueLabel", "Value")
        enterVerb = d.str("enterVerb", "becomes")
        leaveVerb = d.str("leaveVerb", "leaves")
        example = d.str("example")
        provides = d.strOpt("provides")
        enterWhen = d.strOpt("enterWhen")
        leaveWhen = d.strOpt("leaveWhen")
        bundleIdMatch = d.bool("bundleIdMatch")
        goneOnLeave = d.bool("goneOnLeave")
    }
}

/// Everything the Add-rule form needs to populate its dropdowns (rules.formOptions).
struct RuleFormOptions {
    let signals: [String]
    let signalCandidates: [String: [String]]
    let signalMeta: [String: SignalMeta]
    let events: [String]
    let effects: [RuleEffectOption]
    let layoutDisplays: [String]        // currently-connected display names
    let layoutPositions: [LayoutPosition]

    init(_ dict: [String: Any]) {
        self.signals = dict.strArray("signals")
        var cand: [String: [String]] = [:]
        if let c = dict["signalCandidates"] as? [String: Any] {
            for (k, v) in c { cand[k] = (v as? [Any])?.compactMap { $0 as? String } ?? [] }
        }
        self.signalCandidates = cand
        var meta: [String: SignalMeta] = [:]
        if let m = dict["signalMeta"] as? [String: Any] {
            for (k, v) in m { if let d = v as? [String: Any] { meta[k] = SignalMeta(d) } }
        }
        self.signalMeta = meta
        self.events = dict.strArray("events")
        self.effects = (dict["effects"] as? [Any])?
            .compactMap { $0 as? [String: Any] }.compactMap(RuleEffectOption.init) ?? []
        self.layoutDisplays = dict.strArray("layoutDisplays")
        self.layoutPositions = (dict["layoutPositions"] as? [Any])?
            .compactMap { $0 as? [String: Any] }
            .compactMap { d in (d["id"] as? String).map { LayoutPosition(id: $0, label: d["label"] as? String ?? $0) } } ?? []
    }
}
