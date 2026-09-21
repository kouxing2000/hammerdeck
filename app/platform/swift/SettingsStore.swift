import Foundation
import Combine
import Security

// The config-UI side of the bridge: reads the manifest catalog from the Lua
// registry, and reads/writes the SAME UserDefaults keys the Lua side uses
// (hammerdeck.opt.<id>.<key>), so there is a single settings store. Features
// read options live via ctx.opt, so option edits apply without a restart;
// enable/disable goes through registry.setEnabled so bindings rebind properly.

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

    /// The UI's enable/disable entry point (every toggle / "Enable" button). The
    /// change ALWAYS goes through; enabling a feature that needs Accessibility we
    /// do not have also kicks off the grant flow.
    ///
    /// It does not refuse. Onboarding is LAZY and per-use by design, stated at
    /// `ctx.lua`'s input gate: a generic up-front gate "would also short-circuit
    /// the window features, replacing their situation-specific onboarding with a
    /// generic one". `windows.focusedOrAlert` and `inputAllowed` each prompt AND
    /// explain, naming the feature, at the moment the user reaches for it.
    ///
    /// A refusal here contradicted that, and could not hold the line anyway --
    /// `defaultEnabled` binds the seven ungranted window features at boot without
    /// consulting `requires`, and `enableEssentials` calls `registry.setEnabled`
    /// directly. Refusing on one of three paths only produced a catalog where the
    /// Essentials button enabled what the Toggle beside it rejected, and where a
    /// feature that shipped on could not be switched back on.
    /// Returns nothing: the change always goes through. A `Bool` here would be a
    /// signal that cannot go false, and every call site already discards it.
    func requestSetEnabled(_ id: String, _ on: Bool) {
        setEnabled(id, on)
        // `axTrusted` rather than a second seam call: `setEnabled` ends in
        // `refresh()`, which just assigned it from the live read one line ago.
        if on,
           features.first(where: { $0.id == id })?.requires.contains("accessibility") == true,
           !axTrusted {
            promptAccessibility()     // system prompt + heads-up + open the pane
        }
    }

    /// Hot-reload all features from disk: drops cached Lua modules, re-loads the
    /// catalog, and re-binds whatever was enabled. Enabled-state/options persist.
    ///
    /// Silent, because most callers are the option editors re-registering after a
    /// saved change -- a notice on every edited option would be noise. A reload a
    /// human ASKED for goes through `userReload` instead.
    func reload() {
        _ = try? lua.call("platform.registry", "reload")
        refresh()
    }

    /// A reload the user asked for, which says what it found.
    ///
    /// Here rather than in the menubar handler because there are four such
    /// buttons -- the menulet, the Homepage sidebar, the Gallery's refresh, and
    /// picking an extensions folder -- and wiring the notice to one of them is
    /// how the sidebar button ends up the silent one. Reload Features also
    /// carries a key equivalent, so this is `flash` (single-slot, each replacing
    /// the last) rather than `show`, whose cards would stack on a held key.
    func userReload() {
        reload()
        Toast.flash(symbol: "arrow.clockwise", text: reloadSummary, seconds: 2.5)
    }

    /// One line describing the catalog the last scan produced.
    ///
    /// Derived from `features`, which the UI is already rendering, rather than
    /// from a count handed back by Lua: two producers of the same number drift,
    /// and the failed rows are in here already.
    var reloadSummary: String {
        let live = features.filter { !$0.failed }.count
        let base = String(format: Strings.plural("reload.features", live,
                                                 one: "%d feature reloaded",
                                                 other: "%d features reloaded"), live)
        guard let ext = extensionsStatus else { return base }
        return base + " -- " + ext
    }

    /// What the last scan found in the user's extensions folder, or nil when no
    /// folder is set.
    ///
    /// The empty and the all-failed cases read differently on purpose: they were
    /// indistinguishable before, and "nothing appeared" after writing an
    /// extension is a very different problem from "it was rejected".
    /// Whether any extension in that folder was rejected -- the one state the
    /// status line renders in red. A flag rather than the caller matching on the
    /// message, which is localized and would never match in zh-Hans.
    var extensionsHaveFailures: Bool {
        ExtensionsPreference.dir != nil && features.contains { $0.isExtension && $0.failed }
    }

    var extensionsStatus: String? {
        guard ExtensionsPreference.dir != nil else { return nil }
        let mine = features.filter { $0.isExtension }
        let failed = mine.filter { $0.failed }.count
        let loaded = mine.count - failed
        if failed > 0 {
            return String(format: Strings.t("reload.extensions_failed",
                                            default: "%1$d of %2$d extensions failed to load -- see Open Logs"),
                          failed, mine.count)
        }
        if loaded == 0 {
            return Strings.t("reload.extensions_none",
                             default: "no extensions found -- each one is a subfolder containing lua/init.lua")
        }
        return String(format: Strings.plural("reload.extensions", loaded,
                                             one: "%d extension", other: "%d extensions"), loaded)
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
            return KeychainBox.get(optKey(featureId, opt.key))
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
            if s.isEmpty { KeychainBox.delete(key) } else { KeychainBox.set(key, s) }
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
            KeychainBox.delete(optKey(featureId, opt.key))
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
            return KeychainBox.get(optKey(featureId, opt.key)) != nil
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
        guard let key = KeychainBox.get(optKey(featureId, secretKey)), !key.isEmpty else {
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
            guard KeychainBox.get(self.optKey(featureId, secretKey)) == key else { return }
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
/// here (host config surface, same role as KeychainBox) -- a new provider adds
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
        // Through the seam, NOT a URLSession of our own: Native.httpTask is the
        // app's single outbound HTTP path (see Native+Network). This used to mirror
        // it here, which made the host itself an exception to the rule the whole
        // architecture rests on -- one egress point, in the seam, for features and
        // host UI alike.
        Native.httpTask(url: url, headers: ["Authorization": "Bearer \(key)"],
                        timeout: 20) { status, data, error in
            let finish: @Sendable (Result<[String], Failure>) -> Void = { r in
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(r) } }
            }
            if let error { return finish(.failure(Failure(message: error.localizedDescription))) }
            guard status != 0 else { return finish(.failure(Failure(message: "No response"))) }
            guard status == 200 else {
                return finish(.failure(Failure(message: status == 401 ? "Invalid API key"
                                                                      : "HTTP \(status)")))
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

// Secret `secret` options round-trip through KeychainBox (the shared
// login-Keychain accessor). The config UI here is just one of its two callers;
// the Lua seam (Native+Keychain.swift) is the other, and both use the SAME
// service + account string so what Settings writes is what ctx.secret reads.
