import Foundation
import Combine
import Security

// The config-UI side of the bridge: reads the manifest catalog from the Lua
// registry, and reads/writes the SAME UserDefaults keys the Lua side uses
// (hammerdeck.opt.<id>.<key>), so there is a single settings store. Features
// read options live via ctx.opt, so option edits apply without a restart;
// enable/disable goes through registry.setEnabled so bindings rebind properly.

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
    let context: String         // WHEN it applies -- the primary grouping axis (FeatureContext)
    let requires: [String]      // OS preconditions, e.g. ["accessibility"]
    let recommended: Bool       // part of the curated "Essentials" starter set
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
        self.context = dict.str("context", "anywhere")
        self.requires = dict.strArray("requires")
        self.recommended = dict.bool("recommended")
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

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var features: [FeatureInfo] = []
    @Published var optionEpoch = 0   // bumped on writes so editors refresh
    /// Per-secret validation status, keyed by "<featureId>.<secretKey>". Absent =
    /// fall back to the persisted validated flag (see validationState).
    @Published var validation: [String: ValidationState] = [:]

    /// The feature the embedded Settings tab should focus. The Feature Gallery
    /// sets this before switching to the Settings tab so a card click deep-links
    /// straight to that feature's detail; SettingsPane binds its list selection to it.
    @Published var selectedFeatureId: String?

    /// The rule the Rules page should open for editing. The Automation Timeline
    /// sets this when a rule entry is clicked (a deep-link), then the shell
    /// switches to the Rules tab; RulesPageView consumes + clears it. Mirrors
    /// `selectedFeatureId` for the Settings tab.
    @Published var selectedRuleId: String?

    /// The automation rules, as the Rules page renders them. Loaded by
    /// refreshRules() (the Rules detail calls it onAppear and after each edit).
    @Published private(set) var rules: [RuleInfo] = []

    /// Live Accessibility-grant state, refreshed by `refresh()`. Published so the
    /// gallery/tour permission badges and the Dashboard status row react when the
    /// grant lands (the user returns from System Settings and the window refocuses).
    @Published private(set) var axTrusted = false

    private let lua: LuaState

    init(lua: LuaState) {
        self.lua = lua
    }

    func refresh() {
        guard let list = callList("platform.registry", "describe",
                                  decode: { ($0 as? [String: Any]).flatMap(FeatureInfo.init) }) else {
            print("[hammerdeck] settings: failed to read catalog")
            return
        }
        features = list
        axTrusted = accessibilityTrusted()
    }

    /// Feature-contributed native pages to dock in the Homepage sidebar: every
    /// ENABLED, non-failed feature whose manifest DECLARES a page AND has a Swift
    /// view REGISTERED for its id. All three are required -- a declaration with no
    /// registered view (or vice versa) is silently skipped, so the sidebar never
    /// offers a dead link, and a disabled feature withdraws its page along with the
    /// rest of its surface. Catalog order is preserved.
    func featurePages() -> [FeatureInfo] {
        features.filter { $0.enabled && !$0.failed && $0.page != nil
            && FeaturePageRegistry.shared.isRegistered($0.id) }
    }

    /// Whether `id`'s contributed page should render in the detail pane -- the SAME
    /// gate as featurePages(), so a stale `.feature` selection (e.g. the user just
    /// disabled the feature whose page was open) falls back instead of stranding an
    /// orphaned page next to a sidebar that no longer lists it.
    func showsPage(_ id: String) -> Bool { featurePages().contains { $0.id == id } }

    // MARK: - Bridge reader helpers
    //
    // Every "read from Lua" in this store funnels through these three, so the
    // decode shape (`try? lua.call(...).first`, the `as?` cast, the failure
    // default) lives in ONE place instead of being re-typed at each call site --
    // killing the per-site `?? default` drift the audit flagged.

    /// The single-result primitive: `module.function(args)` -> first result, or
    /// nil on any Lua error. Also the seam a host-side PAGE view uses to pull data
    /// from a feature reader module; callValue/callList are typed wrappers over it.
    func readerCall(_ module: String, _ function: String, _ args: [LuaArg] = []) -> Any? {
        (try? lua.call(module, function, args).first) ?? nil
    }

    /// Typed single-result reader: readerCall + an `as? T` cast. nil if the call
    /// failed OR the result wasn't a T -- callers supply their own `?? default`.
    func callValue<T>(_ module: String, _ function: String, _ args: [LuaArg] = []) -> T? {
        guard let raw = readerCall(module, function, args) else { return nil }
        return raw as? T
    }

    /// Typed array reader: each element decoded through `decode`. nil when the
    /// call failed or the result wasn't a Lua array -- distinct from an empty
    /// array, which decodes to [] (so a reader can tell "no data" from "failed").
    func callList<T>(_ module: String, _ function: String, _ args: [LuaArg] = [],
                     decode: (Any) -> T?) -> [T]? {
        guard let raw = readerCall(module, function, args), let list = raw as? [Any] else { return nil }
        return list.compactMap(decode)
    }

    /// Two-result reader for the engine's `true` / `false, reason` shape. nil when
    /// the call itself threw (the caller picks the "could not ..." wording); else
    /// (ok, reason) where reason is the second result (may be nil/"").
    func callOkReason(_ module: String, _ function: String,
                      _ args: [LuaArg] = []) -> (ok: Bool, reason: String?)? {
        guard let r = try? lua.call(module, function, args, results: 2) else { return nil }
        return ((r[0] as? Bool) == true, r[1] as? String)
    }

    /// Enable the curated "Essentials" set (features marked `recommended`) in one
    /// go -- the blank-start safety net so closing the Tour at zero isn't a dead
    /// app. No-op for already-enabled or broken features.
    func enableEssentials() {
        for f in features where f.recommended && !f.failed && !f.enabled {
            _ = try? lua.call("platform.registry", "setEnabled", [.string(f.id), .bool(true)])
        }
        refresh()
    }

    func setEnabled(_ id: String, _ on: Bool) {
        do {
            try lua.call("platform.registry", "setEnabled", [.string(id), .bool(on)])
        } catch {
            print("[hammerdeck] settings: setEnabled failed: \(error)")
        }
        refresh()
    }

    /// The UI's enable/disable entry point (every toggle / "Enable" button). Trying
    /// to ENABLE a feature that needs Accessibility we don't have yet FAILS (it
    /// would otherwise sit "on" but silently no-op) and opens the grant flow
    /// instead -- so the user grants, then enables. Disabling, or enabling a
    /// feature that has the grant or doesn't need it, passes straight through.
    /// (setEnabled stays the pure op the integration tests drive directly, so this
    /// gate never fires -- or opens System Settings -- during `swift test`.)
    /// Returns whether the change went through.
    @discardableResult
    func requestSetEnabled(_ id: String, _ on: Bool) -> Bool {
        // Order matters: cheap checks first, then the LIVE seam read (not the cached
        // axTrusted, which only refresh() updates -- a grant made on a non-home tab
        // would otherwise lag and wrongly refuse the enable).
        if on,
           features.first(where: { $0.id == id })?.requires.contains("accessibility") == true,
           !accessibilityTrusted() {
            promptAccessibility()     // auto-onboard: system prompt + heads-up + open the pane
            // The refusal mutates no @Published state, so a Toggle bound to
            // feature.enabled would stay visually ON -- the exact lie this gate
            // exists to prevent. Nudge observers so the switch snaps back to OFF.
            objectWillChange.send()
            return false              // enable refused until the grant lands
        }
        setEnabled(id, on)
        return true
    }

    /// Hot-reload all features from disk: drops cached Lua modules, re-loads the
    /// catalog, and re-binds whatever was enabled. Enabled-state/options persist.
    func reload() {
        _ = try? lua.call("platform.registry", "reload")
        refresh()
    }

    // MARK: - Automation rules (Rules page; delegates to the tested rules.lua engine)

    /// Re-read the rule list from the engine into `rules`.
    func refreshRules() {
        rules = callList("platform.rules", "describe",
                         decode: { ($0 as? [String: Any]).flatMap(RuleInfo.init) }) ?? []
    }

    /// The plain-language read-back of an in-progress rule spec (JSON), shown live
    /// above the rule form -- e.g. "When Slack loses focus, minimize it." Composed by
    /// the engine (one source of truth with the list rows). "" when the spec is too
    /// incomplete to read, so the form shows its placeholder instead.
    func ruleSentence(_ json: String) -> String {
        callValue("platform.rules", "sentenceJSON", [.string(json)]) ?? ""
    }

    /// The dropdown source for the Add-rule form (signals, candidates, events, effects).
    func ruleFormOptions() -> RuleFormOptions {
        guard let dict: [String: Any] = callValue("platform.rules", "formOptions") else {
            return RuleFormOptions([:])
        }
        return RuleFormOptions(dict)
    }

    /// Snapshot the current window arrangement as layout placements (the layout
    /// editor's "Capture current layout"). Each dict is { app, screen, pos } where
    /// pos is a { x,y,w,h } ratio table. `onlyDisplay` (the rule's trigger display)
    /// restricts the snapshot to that one display; empty captures every external
    /// display.
    func captureLayout(onlyDisplay: String = "") -> [[String: Any]] {
        let args: [LuaArg] = onlyDisplay.isEmpty ? [] : [.string(onlyDisplay)]
        return callList("platform.rules", "captureLayout", args,
                        decode: { $0 as? [String: Any] }) ?? []
    }

    /// Toggle a rule on/off (binds/unbinds in the engine + persists).
    func setRuleEnabled(_ id: String, _ on: Bool) {
        _ = try? lua.call("platform.rules", "setEnabled", [.string(id), .bool(on)])
        refreshRules()
    }

    /// Delete a rule.
    func removeRule(_ id: String) {
        _ = try? lua.call("platform.rules", "remove", [.string(id)])
        refreshRules()
    }

    /// Fire a rule's effect ON DEMAND (the Rules list "Test" button) -- bypasses
    /// the trigger so the user can verify the effect without staging the real
    /// condition (plugging in a monitor, switching apps). Returns (ok, message):
    /// message is a partial-success note or a failure reason ("" on a clean fire).
    func fireRule(_ id: String) -> (ok: Bool, message: String) {
        guard let r = callOkReason("platform.rules", "fire", [.string(id)]) else {
            return (false, "could not run the rule")
        }
        return (r.ok, r.reason ?? "")
    }

    /// Add a rule from a JSON spec string. The engine validates (shape + context
    /// policy); returns nil on success or a human-readable reason on refusal.
    func addRule(_ json: String) -> String? {
        defer { refreshRules() }
        guard let r = callOkReason("platform.rules", "addJSON", [.string(json)]) else {
            return "could not add rule"
        }
        return r.ok ? nil : (r.reason ?? "invalid rule")
    }

    /// One rule's stored spec as pretty-printed JSON (the advanced "Edit as JSON"
    /// editor's source). The engine emits canonical (compact) JSON; we re-indent it
    /// for editing and SURFACE optional fields so they're discoverable -- a layout
    /// placement that has no `titlePattern` gets an empty one, so the editor shows
    /// the field exists (an unfilled "" is ignored at match time). Returns "" if the
    /// rule is unknown / unencodable.
    func ruleSpecJSON(_ id: String) -> String {
        guard let compact: String = callValue("platform.rules", "specJSON", [.string(id)]) else { return "" }
        guard let data = compact.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return Self.prettyJSON(compact) }
        if var effect = obj["effect"] as? [String: Any],
           effect["kind"] as? String == "layout",
           let places = effect["placements"] as? [[String: Any]] {
            effect["placements"] = places.map { p -> [String: Any] in
                var p = p
                if p["titlePattern"] == nil { p["titlePattern"] = "" }  // surface the field
                return p
            }
            obj["effect"] = effect
        }
        guard let pretty = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: pretty, encoding: .utf8) else { return Self.prettyJSON(compact) }
        return s
    }

    /// Re-indent a compact JSON string for human editing (sorted keys, 2-space).
    /// Falls back to the input unchanged if it can't be parsed.
    static func prettyJSON(_ compact: String) -> String {
        guard let data = compact.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: pretty, encoding: .utf8) else { return compact }
        return s
    }

    /// Update an existing rule in place from a JSON spec (the edit form's "Save
    /// changes"). Keeps the id; same validation as add. nil on success / reason on refusal.
    func updateRule(_ id: String, _ json: String) -> String? {
        defer { refreshRules() }
        guard let r = callOkReason("platform.rules", "updateJSON", [.string(id), .string(json)]) else {
            return "could not update rule"
        }
        return r.ok ? nil : (r.reason ?? "invalid rule")
    }

    // MARK: - Trigger rebinding (delegates to the tested registry.setTrigger)

    /// Rebind one action of a feature. Returns nil on success, or a
    /// human-readable reason if the registry refused (e.g. hotkey already taken).
    func setTrigger(_ id: String, _ actionId: String, _ spec: TriggerSpec) -> String? {
        defer { refresh() }
        // setTrigger returns `true` or `false, reason` -- read both results.
        guard let r = callOkReason("platform.registry", "setTrigger",
                                   [.string(id), .string(actionId), spec.luaArg]) else {
            return "could not apply trigger"
        }
        return r.ok ? nil : (r.reason ?? "trigger conflict")
    }

    /// Advisory (soft) conflicts for a candidate hotkey/chord binding: macOS
    /// system shortcuts it collides with, plus common app shortcuts it would
    /// shadow. Distinct from setTrigger's hard, in-app conflict (which blocks).
    /// Empty when clear; the caller still lets the user apply.
    func shortcutAdvisories(_ spec: TriggerSpec) -> [String] {
        guard spec.type == "hotkey" || spec.type == "chord" else { return [] }
        return callList("platform.triggers", "advisories", [spec.luaArg],
                        decode: { $0 as? String }) ?? []
    }

    /// Read-only hard-conflict check: does `spec` collide with another ENABLED
    /// Hammerdeck action? Returns the reason, or nil. Mirrors what setTrigger
    /// would refuse -- used to render a row's live status WITHOUT mutating
    /// anything (setTrigger persists; this doesn't).
    func triggerConflict(_ id: String, _ actionId: String, _ spec: TriggerSpec) -> String? {
        callValue("platform.registry", "triggerConflict",
                  [.string(id), .string(actionId), spec.luaArg])
    }

    /// Feature ids with at least one shortcut conflict on a currently-bound
    /// hotkey/chord action -- either a hard in-app collision (triggerConflict)
    /// or a soft system/common-app advisory (shortcutAdvisories). Powers the
    /// Gallery's "has conflict" filter and per-card warning badge. Reads from
    /// the in-memory `features` snapshot, so refresh() first if the catalog may
    /// be stale.
    func conflictedFeatureIds() -> Set<String> {
        var out: Set<String> = []
        for f in features where !f.failed {
            for a in f.actions {
                guard let t = a.trigger, t.type == "hotkey" || t.type == "chord" else { continue }
                if triggerConflict(f.id, a.id, t) != nil || !shortcutAdvisories(t).isEmpty {
                    out.insert(f.id)
                    break
                }
            }
        }
        return out
    }

    /// Whether the process holds the Accessibility grant -- read through the
    /// seam (native.ax_trusted via adapter.axTrusted), never by calling the OS
    /// API from the UI. Powers the Dashboard's permission status row.
    func accessibilityTrusted() -> Bool {
        callValue("platform.adapter", "axTrusted") ?? false
    }

    /// Onboard the Accessibility grant THROUGH THE SEAM (never a direct OS call
    /// from the UI -- the one inviolable rule). Apple's "...would like to control
    /// this computer" dialog (axPrompt) registers Hammerdeck in the Accessibility
    /// list AND carries its own "Open System Settings" button -- so firing it AND
    /// yanking to Settings at the same instant is a redundant double. There's no
    /// API to know whether that dialog actually showed (the return is just trust
    /// status) and it appears only ONCE per app. So: show the dialog now, then a
    /// few seconds later open the pane ourselves ONLY if still ungranted -- which
    /// covers the case where the once-per-app dialog was already used and won't
    /// reappear, without stacking Settings on top of a fresh dialog. The grant
    /// lands out-of-process, so `axTrusted` updates on the next refresh().
    private static let axSettingsFallbackDelay: TimeInterval = 3
    private var axOnboardingInFlight = false
    func promptAccessibility() {
        // Debounce: one onboarding cycle at a time, so toggling several AX features
        // (or a re-click) doesn't stack toasts + Settings-opens. Cleared when the
        // delayed open fires.
        if axOnboardingInFlight { return }
        axOnboardingInFlight = true
        _ = try? lua.call("platform.adapter", "axPrompt")
        // Tell the user the pane is coming, so the auto-open isn't a surprise.
        let secs = Int(Self.axSettingsFallbackDelay)
        _ = try? lua.call("platform.adapter", "notify", [
            .string("Accessibility needed"),
            .string("Opening System Settings in \(secs) seconds -- turn on \(AppInfo.displayName) there, "
                  + "then enable the feature again."),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.axSettingsFallbackDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.axOnboardingInFlight = false
                guard !self.accessibilityTrusted() else { return }
                _ = try? self.lua.call("platform.adapter", "axOpenSettings")
            }
        }
    }

    /// Swap two actions' triggers (the Shortcut Map drag-to-swap). Atomic and
    /// conflict-safe in the registry. Refreshes the catalog after.
    func swapTriggers(_ idA: String, _ actionA: String, _ idB: String, _ actionB: String) {
        _ = try? lua.call("platform.registry", "swapTriggers",
                      [.string(idA), .string(actionA), .string(idB), .string(actionB)])
        refresh()
    }

    /// Drop one action's override, reverting to its declared default trigger.
    func clearTrigger(_ id: String, _ actionId: String) {
        _ = try? lua.call("platform.registry", "clearTrigger", [.string(id), .string(actionId)])
        refresh()
    }

    /// Fire one action of an enabled feature on demand (menubar quick triggers).
    func runAction(_ id: String, _ actionId: String) {
        _ = try? lua.call("platform.registry", "runAction", [.string(id), .string(actionId)])
    }

    /// Run a feature's option-action (a Settings "Test" button). Fire-and-forget;
    /// the handler surfaces its own result to the user (alert / app focus).
    func runOptionAction(_ featureId: String, _ opt: OptionInfo) {
        _ = try? lua.call("platform.registry", "runOptionAction", [.string(featureId), .string(opt.key)])
    }

    // MARK: - Option values (UserDefaults, same keys as ctx.opt)

    private func optKey(_ featureId: String, _ key: String) -> String {
        "hammerdeck.opt.\(featureId).\(key)"
    }

    /// Stored override, or the manifest default. `secret`-typed options live in
    /// the login Keychain (same account namespace ctx.secret reads), never in
    /// UserDefaults, and have NO manifest default fallback.
    func optionValue(_ featureId: String, _ opt: OptionInfo) -> Any? {
        if opt.type == "secret" {
            return KeychainStore.get(optKey(featureId, opt.key))
        }
        let v = UserDefaults.standard.object(forKey: optKey(featureId, opt.key))
        switch v {
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? n.boolValue : n.doubleValue
        case let s as String:
            return s
        default:
            return opt.defaultValue
        }
    }

    func setOptionValue(_ featureId: String, _ opt: OptionInfo, _ value: Any?) {
        let key = optKey(featureId, opt.key)
        if opt.type == "secret" {
            let s = value as? String ?? ""
            if s.isEmpty { KeychainStore.delete(key) } else { KeychainStore.set(key, s) }
            // Editing a validatable credential invalidates any prior validation:
            // re-lock the gated options until the user validates the new key.
            if opt.validate != nil {
                UserDefaults.standard.set(false, forKey: validatedStateKey(featureId, opt.key))
                validation[validationLookupKey(featureId, opt.key)] = .idle
            }
            optionEpoch += 1
            notifyOptionChanged(featureId, opt.key)
            return
        }
        switch value {
        case let b as Bool:   UserDefaults.standard.set(b, forKey: key)
        case let d as Double: UserDefaults.standard.set(d, forKey: key)
        case let i as Int:    UserDefaults.standard.set(Double(i), forKey: key)
        case let s as String: UserDefaults.standard.set(s, forKey: key)
        default:              UserDefaults.standard.removeObject(forKey: key)
        }
        optionEpoch += 1
        notifyOptionChanged(featureId, opt.key)
    }

    func resetOption(_ featureId: String, _ opt: OptionInfo) {
        if opt.type == "secret" {
            KeychainStore.delete(optKey(featureId, opt.key))
        } else {
            UserDefaults.standard.removeObject(forKey: optKey(featureId, opt.key))
        }
        optionEpoch += 1
        notifyOptionChanged(featureId, opt.key)
    }

    /// Let an enabled feature react to the edit immediately (registry no-ops
    /// for features without an onOptionChange handler).
    private func notifyOptionChanged(_ featureId: String, _ key: String) {
        _ = try? lua.call("platform.registry", "optionChanged", [.string(featureId), .string(key)])
    }

    func isOptionOverridden(_ featureId: String, _ opt: OptionInfo) -> Bool {
        if opt.type == "secret" {
            return KeychainStore.get(optKey(featureId, opt.key)) != nil
        }
        return UserDefaults.standard.object(forKey: optKey(featureId, opt.key)) != nil
    }

    // MARK: - Credential validation (validate-able secrets)

    // The DURABLE validated flag + fetched choices live in the feature-STATE
    // namespace (hammerdeck.state.<id>.<key>__*), not the option namespace, so:
    //  - the Lua feature reads the flag via ctx.getState("<key>__validated"), and
    //  - they are never confused with a user-set option override.
    private func validatedStateKey(_ id: String, _ secretKey: String) -> String {
        "hammerdeck.state.\(id).\(secretKey)__validated"
    }
    private func modelsStateKey(_ id: String, _ secretKey: String) -> String {
        "hammerdeck.state.\(id).\(secretKey)__models"
    }
    private func validationLookupKey(_ id: String, _ secretKey: String) -> String {
        "\(id).\(secretKey)"
    }

    /// Has this secret been successfully validated (and not edited since)? Reads
    /// the durable flag, so it survives relaunch. Powers gatedBy graying.
    func isValidated(_ featureId: String, _ secretKey: String) -> Bool {
        UserDefaults.standard.bool(forKey: validatedStateKey(featureId, secretKey))
    }

    /// The dynamic choices a `valuesFrom` enum should show -- the list fetched by
    /// the last successful validate, or [] before one (caller falls back to seed).
    func fetchedChoices(_ featureId: String, _ secretKey: String) -> [String] {
        guard let s = UserDefaults.standard.string(forKey: modelsStateKey(featureId, secretKey)),
              let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }
    }

    /// The editor's status for a secret: the live in-session state if any, else
    /// derived from the durable validated flag (so a validated key reads "ok"
    /// after a relaunch without re-checking the network).
    func validationState(_ featureId: String, _ secretKey: String) -> ValidationState {
        if let s = validation[validationLookupKey(featureId, secretKey)] { return s }
        return isValidated(featureId, secretKey) ? .ok(Strings.t("settings.validated", default: "Validated")) : .idle
    }

    /// Validate a secret against its provider (opt.validate), then on success
    /// record the durable flag + fetched choices and reconcile the dependent
    /// model selection. Async: the editor reflects `validation[...]` as it moves
    /// idle -> validating -> ok/failed.
    func validate(_ featureId: String, _ opt: OptionInfo) {
        let secretKey = opt.key
        let lookup = validationLookupKey(featureId, secretKey)
        guard let key = KeychainStore.get(optKey(featureId, secretKey)), !key.isEmpty else {
            validation[lookup] = .failed("Enter an API key first")
            return
        }
        let provider = opt.validate ?? "openai"
        validation[lookup] = .validating

        // The enum that draws its choices from this secret -- so we can verify
        // (and, if needed, default) the selection against the fetched list.
        let modelOpt = features.first { $0.id == featureId }?
            .options.first { $0.valuesFrom == secretKey }
        let currentModel = modelOpt.flatMap { optionValue(featureId, $0) as? String }

        SecretValidator.validate(provider: provider, key: key) { [weak self] result in
            guard let self else { return }
            // Stale-result guard: the user may have edited the key while this
            // request was in flight (setOptionValue re-locks the gate). If the
            // stored key no longer matches what we validated, drop this result --
            // otherwise we'd unlock the gate for a key that was never validated.
            guard KeychainStore.get(self.optKey(featureId, secretKey)) == key else { return }
            switch result {
            case .success(let choices):
                UserDefaults.standard.set(true, forKey: self.validatedStateKey(featureId, secretKey))
                if let data = try? JSONSerialization.data(withJSONObject: choices),
                   let s = String(data: data, encoding: .utf8) {
                    UserDefaults.standard.set(s, forKey: self.modelsStateKey(featureId, secretKey))
                }
                var msg = "Key valid -- \(choices.count) models available"
                // Verify the selected model is actually offered; default it if not.
                if let modelOpt, let currentModel, !choices.isEmpty, !choices.contains(currentModel) {
                    let fallback = choices.contains("gpt-4o-mini") ? "gpt-4o-mini" : choices[0]
                    self.setOptionValue(featureId, modelOpt, fallback)
                    msg = "Key valid; model set to \(fallback)"
                }
                self.validation[lookup] = .ok(msg)
            case .failure(let failure):
                UserDefaults.standard.set(false, forKey: self.validatedStateKey(featureId, secretKey))
                self.validation[lookup] = .failed(failure.message)
            }
            self.notifyOptionChanged(featureId, secretKey)
            self.optionEpoch += 1
        }
    }
}

/// Checks a credential against its provider's API. The OpenAI specifics live
/// here (host config surface, same role as KeychainStore) -- a new provider adds
/// a case. Returns the provider's offered chat models on success so a `valuesFrom`
/// enum can populate from the live account.
enum SecretValidator {
    /// A validation failure carrying a human-readable reason (String is not an
    /// Error, so Result needs a typed failure).
    struct Failure: Error, Sendable { let message: String }

    // completion is @MainActor (so it is Sendable and safe to capture in the
    // URLSession @Sendable callback, and the result lands back on the main actor
    // where the store mutates @Published state). Mirrors Native+Network's
    // DispatchQueue.main.async { MainActor.assumeIsolated { ... } } hop.
    @MainActor
    static func validate(provider: String, key: String,
                         completion: @escaping @MainActor (Result<[String], Failure>) -> Void) {
        switch provider {
        case "openai": validateOpenAI(key: key, completion: completion)
        default:       completion(.failure(Failure(message: "Unknown provider '\(provider)'")))
        }
    }

    @MainActor
    private static func validateOpenAI(key: String,
                                       completion: @escaping @MainActor (Result<[String], Failure>) -> Void) {
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            return completion(.failure(Failure(message: "Bad URL")))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, response, error in
            let finish: @Sendable (Result<[String], Failure>) -> Void = { r in
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(r) } }
            }
            if let error { return finish(.failure(Failure(message: error.localizedDescription))) }
            guard let http = response as? HTTPURLResponse else {
                return finish(.failure(Failure(message: "No response")))
            }
            guard http.statusCode == 200 else {
                return finish(.failure(Failure(message: http.statusCode == 401 ? "Invalid API key"
                                                                               : "HTTP \(http.statusCode)")))
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["data"] as? [[String: Any]] else {
                return finish(.failure(Failure(message: "Unexpected response")))
            }
            finish(.success(chatModels(arr.compactMap { $0["id"] as? String })))
        }.resume()
    }

    /// Keep only chat-capable model ids (drop embeddings/audio/image/etc.), sorted.
    private static func chatModels(_ ids: [String]) -> [String] {
        let exclude = ["embedding", "whisper", "tts", "audio", "realtime", "transcribe",
                       "image", "dall-e", "moderation", "babbage", "davinci"]
        return ids.filter { id in
            let l = id.lowercased()
            guard l.hasPrefix("gpt-") || l.hasPrefix("o1") || l.hasPrefix("o3")
                || l.hasPrefix("o4") || l.hasPrefix("chatgpt") else { return false }
            return !exclude.contains { l.contains($0) }
        }.sorted()
    }
}

/// The config UI's write side for `secret` options. Mirrors the Lua-facing
/// `keychain_*` bindings (Native+Keychain.swift): SAME service + account string
/// (`hammerdeck.opt.<id>.<key>`), so what Settings writes is what ctx.secret
/// reads. This is the Swift config surface, not the Lua seam -- the same role
/// SettingsStore already plays mirroring native.get_setting's UserDefaults.
enum KeychainStore {
    static let service = "com.hammerdeck.secrets"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func get(_ account: String) -> String? {
        #if DEBUG
        // Dev: serve secrets from `.env` so the config UI never hits the login
        // Keychain (which re-prompts on every rebuild). See DevEnv.cachedSecret.
        if let value = DevEnv.cachedSecret(account) { return value }
        #endif
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var attrs = baseQuery(account)
        attrs[kSecValueData as String] = Data(value.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
