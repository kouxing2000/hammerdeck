import Foundation
import Combine

// The config-UI side of the bridge: reads the manifest catalog from the Lua
// registry, and reads/writes the SAME UserDefaults keys the Lua side uses
// (hammerdeck.opt.<id>.<key>), so there is a single settings store. Features
// read options live via ctx.opt, so option edits apply without a restart;
// enable/disable goes through registry.setEnabled so bindings rebind properly.

struct OptionInfo: Identifiable {
    let key: String
    let type: String        // bool | int | string | enum | time | appList
    let label: String
    let defaultValue: Any?
    let min: Double?
    let max: Double?
    let values: [String]
    let labels: [String]    // enum display labels, parallel to `values` (may be empty)
    let multiline: Bool     // string: render a multi-line text box (one item per line)
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

    /// Emit as a Lua table literal for registry.setTrigger (single quotes and
    /// backslashes escaped so a hand-typed key can't break the chunk).
    var luaLiteral: String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "'", with: "\\'")
        }
        func list(_ xs: [String]) -> String { xs.map { "'\(esc($0))'" }.joined(separator: ",") }
        switch type {
        case "hotkey":
            return "{type='hotkey',mods={\(list(mods))},key='\(esc(key))'}"
        case "chord":
            return "{type='chord',mods={\(list(mods))},key='\(esc(key))',follows={\(list(follows))}}"
        case "schedule":
            if let everyMin { return "{type='schedule',everyMin=\(everyMin)}" }
            return "{type='schedule',at='\(esc(at ?? "00:00"))'}"
        case "event":
            return "{type='event',event='\(esc(event ?? "wake"))'}"
        default:
            return "{}"
        }
    }
}

// One named, independently triggerable entry point of a feature (a plugin may
// declare several -- each gets its own trigger editor).
struct ActionInfo: Identifiable {
    let id: String
    let label: String
    let trigger: TriggerSpec?           // current (override or default)
    let defaultTrigger: TriggerSpec?    // declared default (may be nil)
    let triggerOverridden: Bool
    let triggerDesc: String

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        self.label = dict["label"] as? String ?? id
        self.trigger = TriggerSpec(dict["trigger"] as? [String: Any])
        self.defaultTrigger = TriggerSpec(dict["defaultTrigger"] as? [String: Any])
        self.triggerOverridden = dict["triggerOverridden"] as? Bool ?? false
        self.triggerDesc = dict["triggerDesc"] as? String ?? ""
    }
}

struct FeatureInfo: Identifiable {
    let id: String
    let name: String
    let description: String
    let category: String
    let version: String
    let kind: String        // action | service
    var enabled: Bool
    let triggerDesc: String
    let options: [OptionInfo]
    let failed: Bool            // load or start error -- the feature is broken
    let errorMessage: String
    let actions: [ActionInfo]   // one trigger editor per entry; empty for pure services

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.description = dict["description"] as? String ?? ""
        self.category = dict["category"] as? String ?? "general"
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
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var features: [FeatureInfo] = []
    @Published var optionEpoch = 0   // bumped on writes so editors refresh

    private let lua: LuaState

    init(lua: LuaState) {
        self.lua = lua
    }

    func refresh() {
        guard let raw = try? lua.eval("return require('platform.registry').describe()"),
              let list = raw as? [Any] else {
            print("[hammerdeck] settings: failed to read catalog")
            return
        }
        features = list.compactMap { $0 as? [String: Any] }.compactMap(FeatureInfo.init)
    }

    func setEnabled(_ id: String, _ on: Bool) {
        do {
            _ = try lua.eval("require('platform.registry').setEnabled('\(id)', \(on)); return true")
        } catch {
            print("[hammerdeck] settings: setEnabled failed: \(error)")
        }
        refresh()
    }

    /// Hot-reload all features from disk: drops cached Lua modules, re-loads the
    /// catalog, and re-binds whatever was enabled. Enabled-state/options persist.
    func reload() {
        _ = try? lua.eval("require('platform.registry').reload(); return true")
        refresh()
    }

    // MARK: - Trigger rebinding (delegates to the tested registry.setTrigger)

    /// Rebind one action of a feature. Returns nil on success, or a
    /// human-readable reason if the registry refused (e.g. hotkey already taken).
    func setTrigger(_ id: String, _ actionId: String, _ spec: TriggerSpec) -> String? {
        let code = """
        local ok, reason = require('platform.registry').setTrigger('\(id)', '\(actionId)', \(spec.luaLiteral))
        return { ok = ok and true or false, reason = reason }
        """
        defer { refresh() }
        guard let raw = try? lua.eval(code), let r = raw as? [String: Any] else {
            return "could not apply trigger"
        }
        if (r["ok"] as? Bool) == true { return nil }
        return (r["reason"] as? String) ?? "trigger conflict"
    }

    /// Advisory (soft) conflicts for a candidate hotkey/chord binding: macOS
    /// system shortcuts it collides with, plus common app shortcuts it would
    /// shadow. Distinct from setTrigger's hard, in-app conflict (which blocks).
    /// Empty when clear; the caller still lets the user apply.
    func shortcutAdvisories(_ spec: TriggerSpec) -> [String] {
        guard spec.type == "hotkey" || spec.type == "chord" else { return [] }
        let code = "return require('platform.triggers').advisories(\(spec.luaLiteral))"
        guard let raw = try? lua.eval(code), let list = raw as? [Any] else { return [] }
        return list.compactMap { $0 as? String }
    }

    /// Read-only hard-conflict check: does `spec` collide with another ENABLED
    /// Hammerdeck action? Returns the reason, or nil. Mirrors what setTrigger
    /// would refuse -- used to render a row's live status WITHOUT mutating
    /// anything (setTrigger persists; this doesn't).
    func triggerConflict(_ id: String, _ actionId: String, _ spec: TriggerSpec) -> String? {
        let code = "local r = require('platform.registry')"
            + ".triggerConflict('\(id)', '\(actionId)', \(spec.luaLiteral)); return r or false"
        guard let raw = try? lua.eval(code), let s = raw as? String else { return nil }
        return s
    }

    /// Swap two actions' triggers (the Shortcut Map drag-to-swap). Atomic and
    /// conflict-safe in the registry. Refreshes the catalog after.
    func swapTriggers(_ idA: String, _ actionA: String, _ idB: String, _ actionB: String) {
        _ = try? lua.eval(
            "require('platform.registry').swapTriggers('\(idA)', '\(actionA)', '\(idB)', '\(actionB)'); return true")
        refresh()
    }

    /// Drop one action's override, reverting to its declared default trigger.
    func clearTrigger(_ id: String, _ actionId: String) {
        _ = try? lua.eval("require('platform.registry').clearTrigger('\(id)', '\(actionId)'); return true")
        refresh()
    }

    /// Fire one action of an enabled feature on demand (menubar quick triggers).
    func runAction(_ id: String, _ actionId: String) {
        _ = try? lua.eval(
            "require('platform.registry').runAction('\(id)', '\(actionId)'); return true")
    }

    // MARK: - Option values (UserDefaults, same keys as ctx.opt)

    private func optKey(_ featureId: String, _ key: String) -> String {
        "hammerdeck.opt.\(featureId).\(key)"
    }

    /// Stored override, or the manifest default.
    func optionValue(_ featureId: String, _ opt: OptionInfo) -> Any? {
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
        UserDefaults.standard.removeObject(forKey: optKey(featureId, opt.key))
        optionEpoch += 1
        notifyOptionChanged(featureId, opt.key)
    }

    /// Let an enabled feature react to the edit immediately (registry no-ops
    /// for features without an onOptionChange handler).
    private func notifyOptionChanged(_ featureId: String, _ key: String) {
        _ = try? lua.eval(
            "require('platform.registry').optionChanged('\(featureId)', '\(key)'); return true")
    }

    func isOptionOverridden(_ featureId: String, _ opt: OptionInfo) -> Bool {
        UserDefaults.standard.object(forKey: optKey(featureId, opt.key)) != nil
    }
}
