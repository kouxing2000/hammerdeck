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
    }

    func resetOption(_ featureId: String, _ opt: OptionInfo) {
        UserDefaults.standard.removeObject(forKey: optKey(featureId, opt.key))
        optionEpoch += 1
    }

    func isOptionOverridden(_ featureId: String, _ opt: OptionInfo) -> Bool {
        UserDefaults.standard.object(forKey: optKey(featureId, opt.key)) != nil
    }
}
