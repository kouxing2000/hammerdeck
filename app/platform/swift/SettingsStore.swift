import Foundation
import Combine
import Security

// The config-UI side of the bridge: reads the manifest catalog from the Lua
// registry, and reads/writes the SAME UserDefaults keys the Lua side uses
// (hammerdeck.opt.<id>.<key>), so there is a single settings store. Features
// read options live via ctx.opt, so option edits apply without a restart;
// enable/disable goes through registry.setEnabled so bindings rebind properly.

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
        self.label = dict["label"] as? String ?? key
        self.defaultValue = dict["default"]
        self.min = dict["min"] as? Double
        self.max = dict["max"] as? Double
        self.values = (dict["values"] as? [Any])?.compactMap { $0 as? String } ?? []
        self.labels = (dict["labels"] as? [Any])?.compactMap { $0 as? String } ?? []
        self.multiline = dict["multiline"] as? Bool ?? false
        self.defaultLabel = dict["defaultLabel"] as? String ?? ""
        self.hint = dict["hint"] as? String ?? ""
        self.section = dict["section"] as? String ?? ""
        self.actionLabel = dict["actionLabel"] as? String ?? ""
        self.preview = dict["preview"] as? String ?? ""
        self.validate = dict["validate"] as? String
        self.gatedBy = dict["gatedBy"] as? String
        self.valuesFrom = dict["valuesFrom"] as? String
        self.collapsible = dict["collapsible"] as? Bool ?? false
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
        self.mods = (dict["mods"] as? [Any])?.compactMap { $0 as? String } ?? []
        self.key = dict["key"] as? String ?? ""
        self.follows = (dict["follows"] as? [Any])?.compactMap { $0 as? String } ?? []
        self.everyMin = (dict["everyMin"] as? Double).map(Int.init)
        self.at = dict["at"] as? String
        self.event = dict["event"] as? String
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
        self.label = dict["label"] as? String ?? id
        self.description = dict["description"] as? String ?? ""
        self.mnemonic = dict["mnemonic"] as? String ?? ""
        self.trigger = TriggerSpec(dict["trigger"] as? [String: Any])
        self.defaultTrigger = TriggerSpec(dict["defaultTrigger"] as? [String: Any])
        self.triggerOverridden = dict["triggerOverridden"] as? Bool ?? false
        self.triggerDesc = dict["triggerDesc"] as? String ?? ""
        self.automatable = dict["automatable"] as? Bool ?? false
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
        self.everyMin = (dict["everyMin"] as? Double).map(Int.init)
        self.at = dict["at"] as? String
        self.event = dict["event"] as? String
        self.note = dict["note"] as? String
        self.optionKey = dict["optionKey"] as? String
        self.category = dict["category"] as? String ?? "general"
    }

    /// Minutes-since-midnight for an `at` entry; nil for non-time entries.
    var minutesOfDay: Int? {
        guard kind == "at", let at, let colon = at.firstIndex(of: ":") else { return nil }
        guard let h = Int(at[at.startIndex..<colon]),
              let m = Int(at[at.index(after: colon)...]) else { return nil }
        return h * 60 + m
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
        self.icon = dict["icon"] as? String ?? "doc"
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
        self.description = dict["description"] as? String ?? ""
        self.category = dict["category"] as? String ?? "general"
        self.context = dict["context"] as? String ?? "anywhere"
        self.requires = (dict["requires"] as? [Any])?.compactMap { $0 as? String } ?? []
        self.recommended = dict["recommended"] as? Bool ?? false
        self.version = dict["version"] as? String ?? ""
        self.kind = dict["kind"] as? String ?? "action"
        self.enabled = dict["enabled"] as? Bool ?? false
        self.triggerDesc = dict["triggerDesc"] as? String ?? ""
        self.options = (dict["options"] as? [Any])?
            .compactMap { $0 as? [String: Any] }
            .compactMap(OptionInfo.init) ?? []
        self.failed = dict["failed"] as? Bool ?? false
        self.errorMessage = dict["error"] as? String ?? ""
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
    let enabled: Bool
    let triggerDesc: String      // "state: frontmostApp becomes Safari", "event: wake", ...
    let effectDesc: String       // 'Notify "Safari is front"', "Run bing_daily.refresh"
    let on: [String: Any]        // raw trigger spec -- pre-fills the edit form
    let effect: [String: Any]    // raw effect node -- pre-fills the edit form

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        self.enabled = dict["enabled"] as? Bool ?? true
        self.triggerDesc = dict["triggerDesc"] as? String ?? ""
        self.effectDesc = dict["effectDesc"] as? String ?? ""
        self.on = dict["on"] as? [String: Any] ?? [:]
        self.effect = dict["effect"] as? [String: Any] ?? [:]
    }
}

/// One selectable effect for the Add-rule form's "Do" dropdown (effects.catalog).
struct RuleEffectOption: Identifiable, Hashable {
    let kind: String             // notify | command
    let label: String
    let feature: String?
    let action: String?
    var id: String { kind == "command" ? "command:\(feature ?? "").\(action ?? "")" : kind }

    init?(_ dict: [String: Any]) {
        guard let kind = dict["kind"] as? String else { return nil }
        self.kind = kind
        self.label = dict["label"] as? String ?? kind
        self.feature = dict["feature"] as? String
        self.action = dict["action"] as? String
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

    init(_ d: [String: Any]) {
        label = d["label"] as? String ?? ""
        valueLabel = d["valueLabel"] as? String ?? "Value"
        enterVerb = d["enterVerb"] as? String ?? "becomes"
        leaveVerb = d["leaveVerb"] as? String ?? "leaves"
        example = d["example"] as? String ?? ""
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
        self.signals = (dict["signals"] as? [Any])?.compactMap { $0 as? String } ?? []
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
        self.events = (dict["events"] as? [Any])?.compactMap { $0 as? String } ?? []
        self.effects = (dict["effects"] as? [Any])?
            .compactMap { $0 as? [String: Any] }.compactMap(RuleEffectOption.init) ?? []
        self.layoutDisplays = (dict["layoutDisplays"] as? [Any])?.compactMap { $0 as? String } ?? []
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
        guard let raw = try? lua.call("platform.registry", "describe").first ?? nil,
              let list = raw as? [Any] else {
            print("[hammerdeck] settings: failed to read catalog")
            return
        }
        features = list.compactMap { $0 as? [String: Any] }.compactMap(FeatureInfo.init)
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

    /// Narrow seam a host-side PAGE view uses to pull data from a feature reader
    /// module (`module.function(args)` -> first result), mirroring how the rest
    /// of the store reaches the registry. Returns nil on any Lua error.
    func readerCall(_ module: String, _ function: String, _ args: [LuaArg] = []) -> Any? {
        (try? lua.call(module, function, args).first) ?? nil
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

    /// Hot-reload all features from disk: drops cached Lua modules, re-loads the
    /// catalog, and re-binds whatever was enabled. Enabled-state/options persist.
    func reload() {
        _ = try? lua.call("platform.registry", "reload")
        refresh()
    }

    // MARK: - Automation rules (Rules page; delegates to the tested rules.lua engine)

    /// Re-read the rule list from the engine into `rules`.
    func refreshRules() {
        guard let raw = try? lua.call("platform.rules", "describe").first ?? nil,
              let list = raw as? [Any] else { rules = []; return }
        rules = list.compactMap { $0 as? [String: Any] }.compactMap(RuleInfo.init)
    }

    /// The dropdown source for the Add-rule form (signals, candidates, events, effects).
    func ruleFormOptions() -> RuleFormOptions {
        guard let raw = try? lua.call("platform.rules", "formOptions").first ?? nil,
              let dict = raw as? [String: Any] else { return RuleFormOptions([:]) }
        return RuleFormOptions(dict)
    }

    /// Snapshot the current window arrangement as layout placements (the layout
    /// editor's "Capture current layout"). Each dict is { app, screen, pos } where
    /// pos is a { x,y,w,h } ratio table.
    func captureLayout() -> [[String: Any]] {
        guard let raw = try? lua.call("platform.rules", "captureLayout").first ?? nil,
              let list = raw as? [Any] else { return [] }
        return list.compactMap { $0 as? [String: Any] }
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

    /// Add a rule from a JSON spec string. The engine validates (shape + context
    /// policy); returns nil on success or a human-readable reason on refusal.
    func addRule(_ json: String) -> String? {
        defer { refreshRules() }
        guard let r = try? lua.call("platform.rules", "addJSON", [.string(json)], results: 2) else {
            return "could not add rule"
        }
        if (r[0] as? Bool) == true { return nil }
        return (r[1] as? String) ?? "invalid rule"
    }

    /// Update an existing rule in place from a JSON spec (the edit form's "Save
    /// changes"). Keeps the id; same validation as add. nil on success / reason on refusal.
    func updateRule(_ id: String, _ json: String) -> String? {
        defer { refreshRules() }
        guard let r = try? lua.call("platform.rules", "updateJSON",
                                    [.string(id), .string(json)], results: 2) else {
            return "could not update rule"
        }
        if (r[0] as? Bool) == true { return nil }
        return (r[1] as? String) ?? "invalid rule"
    }

    // MARK: - Trigger rebinding (delegates to the tested registry.setTrigger)

    /// Rebind one action of a feature. Returns nil on success, or a
    /// human-readable reason if the registry refused (e.g. hotkey already taken).
    func setTrigger(_ id: String, _ actionId: String, _ spec: TriggerSpec) -> String? {
        defer { refresh() }
        // setTrigger returns `true` or `false, reason` -- read both results.
        guard let r = try? lua.call("platform.registry", "setTrigger",
                                    [.string(id), .string(actionId), spec.luaArg], results: 2) else {
            return "could not apply trigger"
        }
        if (r[0] as? Bool) == true { return nil }
        return (r[1] as? String) ?? "trigger conflict"
    }

    /// Advisory (soft) conflicts for a candidate hotkey/chord binding: macOS
    /// system shortcuts it collides with, plus common app shortcuts it would
    /// shadow. Distinct from setTrigger's hard, in-app conflict (which blocks).
    /// Empty when clear; the caller still lets the user apply.
    func shortcutAdvisories(_ spec: TriggerSpec) -> [String] {
        guard spec.type == "hotkey" || spec.type == "chord" else { return [] }
        guard let raw = try? lua.call("platform.triggers", "advisories", [spec.luaArg]).first ?? nil,
              let list = raw as? [Any] else { return [] }
        return list.compactMap { $0 as? String }
    }

    /// Read-only hard-conflict check: does `spec` collide with another ENABLED
    /// Hammerdeck action? Returns the reason, or nil. Mirrors what setTrigger
    /// would refuse -- used to render a row's live status WITHOUT mutating
    /// anything (setTrigger persists; this doesn't).
    func triggerConflict(_ id: String, _ actionId: String, _ spec: TriggerSpec) -> String? {
        guard let raw = try? lua.call("platform.registry", "triggerConflict",
                                      [.string(id), .string(actionId), spec.luaArg]).first ?? nil,
              let s = raw as? String else { return nil }
        return s
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
        (try? lua.call("platform.adapter", "axTrusted").first ?? nil) as? Bool ?? false
    }

    /// Fire the system Accessibility prompt THROUGH THE SEAM (never a direct OS
    /// call from the UI -- the one inviolable rule). The dialog offers to open
    /// System Settings; the grant lands out-of-process, so `axTrusted` updates on
    /// the next refresh() (window refocus), not synchronously here.
    func promptAccessibility() {
        _ = try? lua.call("platform.adapter", "axPrompt")
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
        return isValidated(featureId, secretKey) ? .ok("Validated") : .idle
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
