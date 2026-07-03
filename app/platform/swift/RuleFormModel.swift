import Foundation

// The rule editor's pure data + (de)serialization logic, lifted out of the
// `AddRuleForm` SwiftUI view so it can be unit-tested in isolation (P12, first
// slice). The view holds the live `@State` and bundles it into a `RuleFormModel`
// to call `buildSpec()`; the view's bindings and layout are untouched.
//
// Only `buildSpec` (the rule SERIALIZER -- the form -> engine-spec dict) lives
// here so far; it's the highest-value piece to test, since a bug here silently
// writes a malformed rule. `canSubmit` / `loadForEdit` remain on the view for
// now (a follow-up can move them onto this same model). The trivial trigger/
// effect helpers are re-derived here to keep `buildSpec` self-contained; the
// view keeps its own copies for UI show/hide (they're one-liners).
struct RuleFormModel {
    // MARK: Form data (mirrors AddRuleForm's @State fields buildSpec reads)
    var name = ""
    var triggerType = "state:frontmostApp"
    var transition = "becomes"            // becomes | leaves
    var stateValue = ""
    var stateValueBundleId = ""
    var eventName = "wake"
    var scheduleMode = "everyMin"         // everyMin | at
    var everyMin = 25
    var atTime = "09:00"

    var effectId = "notify"
    var notifyTitle = AppInfo.displayName
    var notifyText = ""
    var notifyChannel = "system"          // system | app
    var placements: [Placement] = []
    var chainSteps: [ChainStep] = []
    var shortcutName = ""
    var openURLValue = ""
    var speakText = ""
    var wallpaperImage = ""
    var solidColor = "#FFFFFF"
    var solidDisplay = ""
    var minimizeAppName = ""
    var minimizeAppBundleId = ""
    var moveApp = ""
    var moveAppBundleId = ""
    var moveDisplay = ""
    var launchAppName = ""
    var launchAppBundleId = ""
    var appearanceMode = "dark"     // setAppearance: dark | light | toggle
    var volumeOp = "up"             // volume: up | down | mute
    var mediaKeyName = "playpause"  // mediaKey: playpause | next | previous

    var opts = RuleFormOptions([:])

    // MARK: Derived (mirror the view's computed helpers)
    var isStateTrigger: Bool { triggerType.hasPrefix("state:") }
    var signal: String {
        isStateTrigger ? String(triggerType.dropFirst("state:".count)) : ""
    }
    var selectedEffect: RuleEffectOption? { opts.effects.first { $0.id == effectId } }
    private var meta: SignalMeta? { opts.signalMeta[signal] }
    private var signalUsesBundleId: Bool { meta?.bundleIdMatch ?? false }

    // MARK: Serialize the form into the engine's rule spec (nil = too incomplete)
    func buildSpec() -> [String: Any]? {
        var on: [String: Any]
        if isStateTrigger {
            let v = stateValue.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty, !signal.isEmpty else { return nil }
            on = ["type": "state", "signal": signal]
            on[transition] = v
            // ONLY an app-identity signal matches by bundle id -- never attach a
            // (possibly stale, left by switching signals) id to a name/enum/set signal,
            // or the engine would match a bundle id it never satisfies (a silent dead
            // rule). Mirrors the engine gate (sig.bundleIdMatch in rules.bindOne).
            let bid = stateValueBundleId.trimmingCharacters(in: .whitespaces)
            if signalUsesBundleId, !bid.isEmpty { on["bundleId"] = bid }
        } else if triggerType == "event" {
            on = ["type": "event", "event": eventName]
        } else if triggerType == "schedule" {
            on = scheduleMode == "everyMin"
                ? ["type": "schedule", "everyMin": everyMin]
                : ["type": "schedule", "at": atTime]
        } else {
            return nil
        }
        guard let eff = selectedEffect else { return nil }
        var effect: [String: Any]
        if eff.kind == "notify" {
            let t = notifyTitle.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            effect = ["kind": "notify", "title": t, "channel": notifyChannel]
            let body = notifyText.trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { effect["text"] = body }
        } else if eff.kind == "layout" {
            let list: [[String: Any]] = placements.compactMap { p in
                let app = p.app.trimmingCharacters(in: .whitespaces)
                let screen = p.screen.trimmingCharacters(in: .whitespaces)
                guard !app.isEmpty, !screen.isEmpty else { return nil }
                var entry: [String: Any] = ["app": app, "screen": screen]
                if p.pos == capturedPosId, let r = p.ratios {
                    entry["pos"] = r            // exact captured ratios
                } else {
                    entry["pos"] = p.pos        // a named snap-grid id
                }
                return entry
            }
            guard !list.isEmpty else { return nil }
            effect = ["kind": "layout", "placements": list]
        } else if eff.kind == "runShortcut" {
            let n = shortcutName.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return nil }
            effect = ["kind": "runShortcut", "name": n]
        } else if eff.kind == "openURL" {
            let u = openURLValue.trimmingCharacters(in: .whitespaces)
            guard !u.isEmpty else { return nil }
            effect = ["kind": "openURL", "url": u]
        } else if eff.kind == "speak" {
            let t = speakText.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            effect = ["kind": "speak", "text": t]
        } else if eff.kind == "solidWallpaper" {
            let d = solidDisplay.trimmingCharacters(in: .whitespaces)
            guard !d.isEmpty else { return nil }
            effect = ["kind": "solidWallpaper", "color": solidColor, "display": d]
        } else if eff.kind == "setWallpaperImage" {
            let img = wallpaperImage.trimmingCharacters(in: .whitespaces)
            let d = solidDisplay.trimmingCharacters(in: .whitespaces)
            guard !img.isEmpty, !d.isEmpty else { return nil }
            effect = ["kind": "setWallpaperImage", "image": img, "display": d]
        } else if eff.kind == "moveAppToDisplay" {
            let a = moveApp.trimmingCharacters(in: .whitespaces)
            let d = moveDisplay.trimmingCharacters(in: .whitespaces)
            guard !a.isEmpty, !d.isEmpty else { return nil }
            effect = ["kind": "moveAppToDisplay", "app": a, "display": d]
            if !moveAppBundleId.isEmpty { effect["appBundleId"] = moveAppBundleId }
        } else if appTargetKinds.contains(eff.kind) {
            let a = minimizeAppName.trimmingCharacters(in: .whitespaces)
            guard !a.isEmpty else { return nil }
            effect = ["kind": eff.kind, "app": a]
            if !minimizeAppBundleId.isEmpty { effect["appBundleId"] = minimizeAppBundleId }
        } else if eff.kind == "launchApp" {
            // The bundle id is the launch key (required); the name rides along for the
            // sentence/log. A typed-name-only pick (no id) is blocked by canSubmit.
            let bid = launchAppBundleId.trimmingCharacters(in: .whitespaces)
            let a = launchAppName.trimmingCharacters(in: .whitespaces)
            guard !bid.isEmpty, !a.isEmpty else { return nil }
            effect = ["kind": "launchApp", "app": a, "appBundleId": bid]
        } else if eff.kind == "chain" {
            // Drop incomplete steps (mirrors layout); keep order.
            let steps: [[String: Any]] = chainSteps.compactMap { s in
                switch s.kind {
                case "notify":
                    let t = s.notifyTitle.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return nil }
                    var e: [String: Any] = ["kind": "notify", "title": t, "channel": s.notifyChannel]
                    let body = s.notifyText.trimmingCharacters(in: .whitespaces)
                    if !body.isEmpty { e["text"] = body }
                    return e
                case "speak":
                    let t = s.speakText.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return nil }
                    return ["kind": "speak", "text": t]
                case "runShortcut":
                    let n = s.shortcutName.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return nil }
                    return ["kind": "runShortcut", "name": n]
                case "openURL":
                    let u = s.url.trimmingCharacters(in: .whitespaces)
                    guard !u.isEmpty else { return nil }
                    return ["kind": "openURL", "url": u]
                case "lockScreen":
                    return ["kind": "lockScreen"]
                case "startScreensaver":
                    return ["kind": "startScreensaver"]
                case "emptyTrash":
                    return ["kind": "emptyTrash"]
                case "eject":
                    return ["kind": "eject"]
                default:
                    return nil
                }
            }
            guard !steps.isEmpty else { return nil }
            effect = ["kind": "chain", "effects": steps]
        } else if eff.kind == "setAppearance" {
            effect = ["kind": "setAppearance", "mode": appearanceMode]
        } else if eff.kind == "volume" {
            effect = ["kind": "volume", "op": volumeOp]
        } else if eff.kind == "mediaKey" {
            effect = ["kind": "mediaKey", "key": mediaKeyName]
        } else if eff.kind == "lockScreen" {
            effect = ["kind": "lockScreen"]
        } else if eff.kind == "startScreensaver" {
            effect = ["kind": "startScreensaver"]
        } else if eff.kind == "emptyTrash" {
            effect = ["kind": "emptyTrash"]
        } else if eff.kind == "eject" {
            effect = ["kind": "eject"]
        } else {
            effect = ["kind": "command", "feature": eff.feature ?? ""]
            if let a = eff.action { effect["action"] = a }
        }
        var spec: [String: Any] = ["on": on, "effect": effect]
        let label = name.trimmingCharacters(in: .whitespaces)
        if !label.isEmpty { spec["name"] = label }
        return spec
    }
}
