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

    /// Is the effect half of the form complete enough to serialize? Asked by the
    /// Submit button. Defined as "build would succeed", so the button can never
    /// disagree with what buildSpec actually produces -- they used to be separate
    /// switches, and had already drifted for launchApp.
    @MainActor
    var effectComplete: Bool {
        guard let eff = selectedEffect else { return false }
        guard let spec = EffectKinds.spec(for: eff.kind) else { return true }  // command
        return spec.build(self) != nil
    }

    // MARK: Serialize the form into the engine's rule spec (nil = too incomplete)
    @MainActor
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
        // One table row per kind (RuleEffectKinds) instead of the if-chain that
        // used to live here -- see that file for why. "command" is the only thing
        // without a row: it is not a fixed kind but a feature+action pair resolved
        // from the live catalog, so it is built here.
        let effect: [String: Any]
        if let spec = EffectKinds.spec(for: eff.kind) {
            guard let built = spec.build(self) else { return nil }
            effect = built
        } else {
            var cmd: [String: Any] = ["kind": "command", "feature": eff.feature ?? ""]
            if let a = eff.action { cmd["action"] = a }
            effect = cmd
        }
        var spec: [String: Any] = ["on": on, "effect": effect]
        let label = name.trimmingCharacters(in: .whitespaces)
        if !label.isEmpty { spec["name"] = label }
        return spec
    }
}
