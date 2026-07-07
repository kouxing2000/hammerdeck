-- test/run.lua -- headless platform + feature tests against the fake adapter.
--
-- Run from the repo root:  lua test/run.lua
--
-- Covers: manifest validation, action-feature trigger binding, service-feature
-- lifecycle, the three MVP features' main flows, and the scoped-ctx guarantee
-- that disable leaks nothing.

-- Shared setup, the `ok`/helpers, the assertion counter, and the per-case world
-- reset all live in test/harness.lua now (RUN_LUA_SPLIT_SPEC Phase 0), so the one
-- `passed` total spans this transitional monolith and the migrating
-- test/cases/<id>.lua files alike. Bootstrap package.path here so `require` can
-- find harness under test/; harness itself installs the co-located loader + seam
-- and pins the deterministic clock.
package.path = "app/?.lua;app/?/init.lua;test/?.lua;" .. package.path
local harness = require("harness")
local t = harness.t
local fake, registry     = t.fake, t.registry
local manifest, triggers = t.manifest, t.triggers
local W, AC              = t.W, t.AC
local ok, rejects        = t.ok, t.rejects
local lastFrame, frameEq = t.lastFrame, t.frameEq
local minutesFromNow     = t.minutesFromNow

-- T0: fake-adapter <-> real-adapter SURFACE PARITY ----------------------------
-- The fake adapter must export exactly the same function surface as the real
-- seam (lua/platform/adapter.lua). Without this, a feature can pass headlessly
-- against a fake contract the real bridge doesn't provide (or the fake can rot
-- with dead reimplementations of removed functions). This pins both directions.
-- It does NOT prove behavioral equivalence -- only that the API shape matches;
-- behavior is covered per-function by the feature tests below and the real-
-- bridge Swift integration suite.
fake.resetOpts()
do
    -- Load the REAL adapter for inspection. adapter.lua assert()s `native` is a
    -- table at load, so stub it (we only read its key set, never call through).
    local savedNative = rawget(_G, "native")
    local savedAdapter = package.loaded["platform.adapter"]
    _G.native = setmetatable({}, { __index = function() return function() end end })
    package.loaded["platform.adapter"] = nil          -- force a fresh real load
    local okLoad, realAdapter = pcall(require, "platform.adapter")
    package.loaded["platform.adapter"] = savedAdapter  -- restore the fake preempt
    _G.native = savedNative
    ok(okLoad and type(realAdapter) == "table",
        "real adapter.lua loads for surface inspection")

    local function funcSet(t)
        local s = {}
        for k, v in pairs(t) do if type(v) == "function" then s[k] = true end end
        return s
    end
    local realFns, fakeFns = funcSet(realAdapter), funcSet(fake.adapter)
    for k in pairs(realFns) do
        ok(fakeFns[k], "fake adapter implements real adapter." .. k)
    end
    for k in pairs(fakeFns) do
        ok(realFns[k], "fake adapter." .. k .. " has a real counterpart (not dead/renamed)")
    end
end

-- T0b: i18n catalog (lookup, fallback, interpolation, plural) -----------------
-- The i18n module is locale-injected (not seam-coupled): configure() with a code
-- + appdir, assert against the shipped app/i18n/zh-Hans.json, then RESET to "en"
-- so the describe() tests below see the inline English source.
fake.resetOpts()
do
    local i18n    = require("platform.i18n")
    local windows = require("platform.windows")
    i18n.configure({ locale = "zh-Hans", appdir = "app" })

    ok(i18n.t("window.noFocused", "No focused window") == "没有聚焦的窗口",
        "i18n.t returns the zh-Hans translation for a global key")
    ok(i18n.t("missing.key", "fallback") == "fallback",
        "i18n.t falls back to the inline default for a missing key")
    ok(i18n.t("missing.key") == "missing.key",
        "i18n.t falls back to the key itself when no default is given")

    -- the template is localized; the caller interpolates -- placeholders are
    -- identical across locales, so string.format fills both %s the same way.
    local msg = string.format(
        i18n.t("window.axRequired", "%s needs Accessibility -- grant %s"),
        "Window Mode", "Hammerdeck")
    ok(msg:find("Window Mode", 1, true) and msg:find("Hammerdeck", 1, true)
        and msg:find("辅助功能", 1, true),
        "i18n template interpolates caller args into the zh-Hans string")

    ok(i18n.category(1) == "other" and i18n.category(5) == "other",
        "zh-Hans plural category collapses to other")
    local forms = { one = "%d window", other = "%d windows" }
    ok(i18n.plural("x.count", 5, forms) == "%d windows",
        "i18n.plural picks the other form from inline forms (no catalog entry)")

    -- platform.windows is a leaf: it localizes through the ctx handed to it, with
    -- NO require of i18n. A shared key resolves via ctx.t's global fallback.
    local alerted
    local fakeCtx = {
        window    = { frame = function() return nil end },
        axTrusted = function() return false end,
        axPrompt  = function() end,
        alert     = function(s) alerted = s end,
        appName   = "Hammerdeck",
        t         = function(k, d) return i18n.tFeature("window_modal", k, d) end,
    }
    windows.focusedOrAlert(fakeCtx, "Window Mode")
    ok(alerted and alerted:find("辅助功能", 1, true) and alerted:find("Hammerdeck", 1, true),
        "platform.windows localizes its Accessibility alert via ctx.t")

    -- P2 localization sweep: every feature that emits runtime user-facing strings
    -- must carry the zh-Hans key the code requests, or ctx.t silently falls back to
    -- English in zh (the leak this pass closed). Assert a representative NEW key per
    -- touched feature resolves to a translation (NOT the English default) -- the
    -- exact missing-key failure the en-locale tests below cannot see.
    do
        local sweep = {
            { "sleep_schedule",  "banner.countdown",    "System sleep in %s  --  Save your work!" },
            { "break_reminder",  "action.lock",         "Lock Screen" },
            { "window_modal",    "hud.footer",          "esc  exit" },
            { "text_actions",    "action.calculate",    "Calculate" },
            { "insert_datetime", "error.tableFormat",   "That format produces a table, not text (avoid *t)" },
            { "window_grid",     "hud.caption",         "press a number to place the window" },
            { "window_grid",     "hud.captionExtend",   "press a cell down-right to extend" },
            { "window_grid",     "flash.span",          "%d×%d region" },
            { "window_snap",     "option.presets.label", "Saved placements" },
            { "window_deck",     "pick.windows",        "Deck which windows?" },
        }
        for _, e in ipairs(sweep) do
            ok(i18n.tFeature(e[1], e[2], e[3]) ~= e[3],
                e[1] .. " localizes runtime key '" .. e[2] .. "' in zh (no English leak)")
        end
    end

    -- Leaf-util invariant: the leaf utils (platform.windows/hotkeys/json/urls/
    -- cyclingChooser) must have ZERO `require` -- that require-freedom is exactly what lets a feature
    -- `require` them safely (the layer map's leaf tier). Nothing else guards this
    -- (no luacheck / CI grep), so assert it HERE: it runs in both `lua test/run.lua`
    -- and `scripts/test-lua.sh` (the exact embedded engine), failing loudly if a
    -- ported window algorithm or a careless edit drags a require into the pure layer.
    -- Code lines only -- a comment mentioning "require" (windows.lua's header does)
    -- is skipped so prose never trips the guard.
    do
        local appdir = require("loader").appdir
        for _, leaf in ipairs({ "windows", "hotkeys", "json", "urls", "cyclingChooser" }) do
            local path = appdir .. "/platform/lua/" .. leaf .. ".lua"
            local fh = assert(io.open(path, "r"), "leaf-guard: cannot open " .. path)
            local offender
            for line in fh:lines() do
                if not line:match("^%s*%-%-") and line:match("require%s*[%(\"']") then
                    offender = line
                    break
                end
            end
            fh:close()
            ok(offender == nil,
                "leaf util platform." .. leaf .. " stays require-free (layer invariant)"
                .. (offender and (" -- found: " .. offender) or ""))
        end
    end

    -- RESET to the source language for the rest of the suite.
    i18n.configure({ locale = "en" })
    ok(i18n.t("window.noFocused", "No focused window") == "No focused window",
        "i18n.t returns the inline English source when locale is en")
    ok(i18n.plural("x.count", 1, forms) == "%d window",
        "en plural category splits one/other")
end

-- T1: all manifests register + validate --------------------------------------
-- loadCatalog (not three register() calls) so the catalog is recorded for the
-- hot-reload test (T11), exactly as the real bootstrap does.
do
fake.resetOpts()
registry.loadCatalog({
    "features.sleep_schedule",
    "features.break_reminder",
    "features.window_switcher",
})
ok(#registry.all() == 3, "3 features registered")

end
-- T2: the manifest contract is enforced ----------------------------------------
fake.resetOpts()
rejects({ api = 99, id = "x", name = "X", action = function() end }, "wrong api version")
rejects({ api = 1, id = "x", name = "X" }, "neither action nor start")
rejects({ api = 1, id = "x", name = "X", action = function() end, start = function() end },
    "both action and start")
rejects({ api = 1, id = "x", name = "X", start = function() end,
    defaultTrigger = { type = "hotkey" } }, "defaultTrigger on a service")
rejects({ api = 1, id = "x", name = "X", action = function() end,
    options = { { key = "k", type = "nope" } } }, "unknown option type")
rejects({ api = 1, id = "x", name = "X", action = function() end,
    options = { { key = "m", type = "enum", values = { "a" }, valuesFrom = "ghost" } } },
    "valuesFrom names no validate-able option")
rejects({ api = 1, id = "x", name = "X", action = function() end,
    options = { { key = "b", type = "bool", default = true, gatedBy = "ghost" } } },
    "gatedBy names no validate-able option")

-- T3 (window_switcher) + T21 (its no-windows onboarding) migrated to
-- test/cases/window_switcher.lua (RUN_LUA_SPLIT_SPEC Phase 2).
-- T4 (sleep_schedule) migrated to test/cases/sleep_schedule.lua;
-- T5 (break_reminder) -> test/cases/break_reminder.lua (RUN_LUA_SPLIT_SPEC Phase 2).
-- T6: nothing leaks globally ----------------------------------------------------
do
fake.resetOpts()
ok(fake.liveHandles == 0, "fake adapter reports zero live native resources")

end
-- T7: catalog description for the config UI --------------------------------------
fake.resetOpts()
local desc = registry.describe()
ok(#desc == 3, "describe lists all 3 features")
ok(desc[1].id == "break_reminder" and desc[1].kind == "service", "describe is sorted by id")
local jumpDesc = desc[3]
ok(jumpDesc.id == "window_switcher" and jumpDesc.kind == "action", "window_switcher is an action")
ok(jumpDesc.triggerDesc == "2 actions", "multi-action feature summarized in the list")
ok(jumpDesc.actions[1].triggerDesc == "hotkey: alt+tab", "per-action trigger described")
ok(type(jumpDesc.actions[1].mnemonic) == "string" and jumpDesc.actions[1].mnemonic:find("⌥Tab"),
    "per-action mnemonic surfaced in describe()")
ok(#jumpDesc.options == 0,
    "window_switcher exports no options (cycle modifier derives from the trigger)")
ok(jumpDesc.context == "window", "describe() surfaces the feature context")
ok(jumpDesc.requires[1] == "accessibility",
    "describe() surfaces OS preconditions (window features need Accessibility)")
-- The per-feature SF Symbol overlaid from feature.json (META_FIELDS) flows all
-- the way to describe(), so the menubar/Settings/Gallery can render it. nil when
-- a feature declares none (host then falls back to the category glyph).
ok(jumpDesc.icon == "macwindow.on.rectangle",
    "describe() surfaces the per-feature icon overlaid from feature.json")
-- typed option export incl. enum values, on a synthetic probe
package.loaded["features._enum_probe"] = {
    api = 1, id = "enum_probe", name = "Enum Probe",
    options = { { key = "mode", type = "enum", default = "a",
                  values = { "a", "b", "c" }, labels = { "Ay", "Bee", "Cee" },
                  label = "Mode" } },
    defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "9" },
    action = function() end,
}
registry.load("features._enum_probe")
local probeDesc0 = nil
for _, e in ipairs(registry.describe()) do
    if e.id == "enum_probe" then probeDesc0 = e end
end
ok(probeDesc0.options[1].key == "mode" and probeDesc0.options[1].type == "enum"
    and #probeDesc0.options[1].values == 3,
    "typed options (incl. enum values) exported for the form generator")
ok(probeDesc0.options[1].labels and probeDesc0.options[1].labels[2] == "Bee",
    "enum display labels exported parallel to values")
registry.unregister("enum_probe")

-- T7c: notify-on-automated-run preference ----------------------------------------
-- An action fired from an AUTOMATED trigger (event/schedule) shows a toast naming
-- the feature ONLY while the notify_on_trigger preference is on. Manual triggers
-- (hotkey/chord) and menubar/palette runs never reach the notify path. Scoped in
-- a `do` block so its locals release (the main chunk is near Lua's 200-local cap).
fake.resetOpts()
do
    package.loaded["features._notify_probe"] = {
        api = 1, id = "notify_probe", name = "Notify Probe",
        actions = { { id = "main", label = "Fire", automatable = true,
                      defaultTrigger = { type = "event", event = "wake" },
                      run = function() end } },
    }
    registry.load("features._notify_probe")
    registry.setEnabled("notify_probe", true)

    fake.settings["hammerdeck.enabled.notify_on_trigger"] = false
    local notifyBefore = #fake.notifications
    fake.systemEvent("wake")
    ok(#fake.notifications == notifyBefore,
        "automated fire with the notify preference OFF shows no notification")

    fake.settings["hammerdeck.enabled.notify_on_trigger"] = true
    fake.systemEvent("wake")
    ok(#fake.notifications == notifyBefore + 1
        and fake.notifications[#fake.notifications].title == "Notify Probe",
        "automated fire with the notify preference ON shows a toast naming the feature")

    -- The SAME action run manually (menubar/palette path) never notifies.
    local notifyManual = #fake.notifications
    registry.runAction("notify_probe", "main")
    ok(#fake.notifications == notifyManual,
        "a manual run does not notify even with the preference on")

    -- A crashed automated run must NOT report as a clean "Ran automatically":
    -- notify is gated on the action succeeding. Firing "wake" runs BOTH the
    -- (ok) notify_probe and this throwing one, so exactly one notification lands.
    package.loaded["features._throw_probe"] = {
        api = 1, id = "throw_probe", name = "Throw Probe",
        actions = { { id = "main", label = "Boom", automatable = true,
                      defaultTrigger = { type = "event", event = "wake" },
                      run = function() error("boom") end } },
    }
    registry.load("features._throw_probe")
    registry.setEnabled("throw_probe", true)
    local throwBefore = #fake.notifications
    fake.systemEvent("wake")
    ok(#fake.notifications == throwBefore + 1,
        "a crashed automated run does not notify (only the successful sibling did)")
    registry.setEnabled("throw_probe", false)
    registry.unregister("throw_probe")

    registry.setEnabled("notify_probe", false)
    registry.unregister("notify_probe")
    fake.settings["hammerdeck.enabled.notify_on_trigger"] = nil
end

-- T7d: confirm-shortcut (manual-trigger flash) -----------------------------------
-- A MANUAL trigger (hotkey/chord) flashes which action fired ONLY while the
-- confirm_shortcut preference is on. Automated triggers take the notify path, not
-- this. Scoped in a `do` block (main-chunk local budget, see T7c).
fake.resetOpts()
do
    package.loaded["features._flash_probe"] = {
        api = 1, id = "flash_probe", name = "Flash Probe", icon = "bolt.fill",
        defaultTrigger = { type = "hotkey", mods = { "ctrl", "alt" }, key = "8" },
        action = function() end,
    }
    registry.load("features._flash_probe")
    registry.setEnabled("flash_probe", true)

    fake.settings["hammerdeck.enabled.confirm_shortcut"] = false
    local flashBefore = #fake.flashes
    fake.pressHotkey("8", { "ctrl", "alt" })
    ok(#fake.flashes == flashBefore,
        "manual hotkey with the confirm preference OFF shows no flash")

    fake.settings["hammerdeck.enabled.confirm_shortcut"] = true
    fake.pressHotkey("8", { "ctrl", "alt" })
    ok(#fake.flashes == flashBefore + 1
        and fake.flashes[#fake.flashes].text == "Flash Probe"
        and fake.flashes[#fake.flashes].symbol == "bolt.fill",
        "manual hotkey with the confirm preference ON flashes the feature name + glyph")

    -- A self-evident feature (opens its own UI) suppresses the flash even with the
    -- preference ON -- the chooser/window it fronts is its own confirmation.
    package.loaded["features._selfev_probe"] = {
        api = 1, id = "selfev_probe", name = "Self Evident Probe", selfEvident = true,
        defaultTrigger = { type = "hotkey", mods = { "ctrl", "alt" }, key = "7" },
        action = function() end,
    }
    registry.load("features._selfev_probe")
    registry.setEnabled("selfev_probe", true)
    local selfevBefore = #fake.flashes
    fake.pressHotkey("7", { "ctrl", "alt" })
    ok(#fake.flashes == selfevBefore,
        "a selfEvident feature does not flash even with confirm_shortcut on")
    registry.setEnabled("selfev_probe", false)
    registry.unregister("selfev_probe")

    registry.setEnabled("flash_probe", false)
    registry.unregister("flash_probe")
    fake.settings["hammerdeck.enabled.confirm_shortcut"] = nil
end

-- T7f: ctx.confirmAction (a modal feature confirms its own real action) ----------
-- A modal feature suppresses the mode-entry flash (selfEvident) and instead fires
-- ctx.confirmAction when the real action lands. That flash is gated on the same
-- confirm_shortcut preference and carries the feature icon. Scoped `do` (see T7c).
fake.resetOpts()
do
    package.loaded["features._confirm_probe"] = {
        api = 1, id = "confirm_probe", name = "Confirm Probe", icon = "star.fill",
        selfEvident = true,   -- entry hotkey must NOT auto-flash; only confirmAction does
        defaultTrigger = { type = "hotkey", mods = { "ctrl", "alt" }, key = "6" },
        action = function(ctx) ctx.confirmAction() end,
    }
    registry.load("features._confirm_probe")
    registry.setEnabled("confirm_probe", true)

    fake.settings["hammerdeck.enabled.confirm_shortcut"] = false
    local cBefore = #fake.flashes
    fake.pressHotkey("6", { "ctrl", "alt" })
    ok(#fake.flashes == cBefore,
        "ctx.confirmAction does not flash while confirm_shortcut is off")

    fake.settings["hammerdeck.enabled.confirm_shortcut"] = true
    fake.pressHotkey("6", { "ctrl", "alt" })
    ok(#fake.flashes == cBefore + 1
        and fake.flashes[#fake.flashes].text == "Confirm Probe"
        and fake.flashes[#fake.flashes].symbol == "star.fill",
        "ctx.confirmAction flashes the feature name + icon once confirm_shortcut is on")

    registry.setEnabled("confirm_probe", false)
    registry.unregister("confirm_probe")
    fake.settings["hammerdeck.enabled.confirm_shortcut"] = nil
end

-- T7g: modal sticky-twin exception (the window_grid Hyper+4 -> cell 4 fix) --------
-- A modal binds each BARE key ALSO under the leader mods (sticky) so the user can
-- hold Hyper through. The entry key is normally EXCLUDED from twinning (so a TOGGLE
-- mode's re-press exits) -- but window_grid's entry key IS a cell, so it passes
-- stickyExceptKey=false to twin every key; else Hyper+<entry> re-enters instead of
-- placing that cell (cells 1-3 work, cell 4 didn't). Scoped `do` (see T7c).
fake.resetOpts()
do
    local modal = require("platform.modal")
    local HYPER = { "cmd", "alt", "ctrl" }
    local function twinBound(key)
        for _, h in ipairs(fake.hotkeys) do
            if not h.stopped and h.key == key and h.mods and #h.mods == 3 then return true end
        end
        return false
    end

    -- Toggle-mode default: the entry key ("4") is excluded from twinning.
    local hExcl = modal.enter({
        stickyMods = HYPER, stickyExceptKey = "4",
        bindings = { { key = "1", fn = function() end }, { key = "4", fn = function() end } },
    })
    ok(twinBound("1") and not twinBound("4"),
        "stickyExceptKey excludes the entry key's sticky twin (Hyper+1 yes, Hyper+4 no)")
    hExcl.stop()

    -- window_grid's fix: exception OFF -> every bare key twins, so Hyper+4 lands cell 4.
    local hAll = modal.enter({
        stickyMods = HYPER, stickyExceptKey = false,
        bindings = { { key = "1", fn = function() end }, { key = "4", fn = function() end } },
    })
    ok(twinBound("1") and twinBound("4"),
        "stickyExceptKey=false twins every bare key (Hyper+4 places cell 4, no re-enter)")
    hAll.stop()
end

-- T7e: defaultEnabled (ships on until the user says otherwise) --------------------
-- A feature with defaultEnabled=true reports enabled when NO stored choice exists,
-- but an explicit toggle always overrides it. Scoped in a `do` block (see T7c).
fake.resetOpts()
do
    package.loaded["features._defon_probe"] = {
        api = 1, id = "defon_probe", name = "Default On Probe",
        defaultEnabled = true, start = function() end,
    }
    registry.load("features._defon_probe")

    fake.settings["hammerdeck.enabled.defon_probe"] = nil
    ok(registry.isEnabled("defon_probe") == true,
        "defaultEnabled=true ships enabled when the user has never toggled it")
    fake.settings["hammerdeck.enabled.defon_probe"] = false
    ok(registry.isEnabled("defon_probe") == false,
        "an explicit user off overrides defaultEnabled=true")

    -- and a plain feature (no defaultEnabled) still ships OFF, as before.
    package.loaded["features._defoff_probe"] = {
        api = 1, id = "defoff_probe", name = "Default Off Probe", start = function() end,
    }
    registry.load("features._defoff_probe")
    fake.settings["hammerdeck.enabled.defoff_probe"] = nil
    ok(registry.isEnabled("defoff_probe") == false,
        "a feature without defaultEnabled stays off by default (blank-slate)")

    registry.unregister("defon_probe")
    registry.unregister("defoff_probe")
    fake.settings["hammerdeck.enabled.defon_probe"] = nil
end

-- labels must be a list parallel to values (and enum-only)
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
    options = { { key = "m", type = "enum", values = { "a", "b" }, labels = { "Only one" } } } }),
    "enum labels length must match values")
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
    options = { { key = "m", type = "string", labels = { "a" } } } }),
    "labels are rejected on a non-enum option")
-- multiline is a string-only boolean flag
ok(pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
    options = { { key = "s", type = "string", multiline = true } } }),
    "multiline accepted on a string option")
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
    options = { { key = "n", type = "int", multiline = true } } }),
    "multiline is rejected on a non-string option")
-- automatable: optional per-action boolean; default false; an automated
-- defaultTrigger implies it must be true.
do
    local m = manifest.validate({ api = 1, id = "x", name = "X", action = function() end })
    ok(m.actions[1].automatable == false, "automatable defaults to false")
    local m2 = manifest.validate({ api = 1, id = "y", name = "Y",
        actions = { { id = "a", run = function() end, automatable = true } } })
    ok(m2.actions[1].automatable == true, "automatable carried through when declared")
end
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X",
    actions = { { id = "a", run = function() end, automatable = "yes" } } }),
    "automatable must be a boolean")
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
    defaultTrigger = { type = "schedule", everyMin = 5 } }),
    "an automated defaultTrigger on a non-automatable action is rejected")
ok(pcall(manifest.validate, { api = 1, id = "x", name = "X",
    actions = { { id = "a", run = function() end, automatable = true,
        defaultTrigger = { type = "schedule", everyMin = 5 } } } }),
    "an automated defaultTrigger is fine when automatable = true")
-- context: optional grouping axis (when the feature applies); controlled vocab;
-- defaults to "anywhere".
do
    local m = manifest.validate({ api = 1, id = "ctxd", name = "Ctxd", action = function() end })
    ok(m.context == "anywhere", "context defaults to anywhere")
    local m2 = manifest.validate({ api = 1, id = "ctxw", name = "Ctxw", context = "window",
        action = function() end })
    ok(m2.context == "window", "context carried through when declared")
end
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", context = "nope",
    action = function() end }), "an unknown context value is rejected")
-- requires: optional OS-precondition list; controlled vocab; defaults to {}.
do
    local m = manifest.validate({ api = 1, id = "reqd", name = "Reqd", action = function() end })
    ok(type(m.requires) == "table" and #m.requires == 0, "requires defaults to an empty list")
    local m2 = manifest.validate({ api = 1, id = "reqa", name = "Reqa",
        requires = { "accessibility" }, action = function() end })
    ok(m2.requires[1] == "accessibility", "requires carried through when declared")
end
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X",
    requires = { "telepathy" }, action = function() end }),
    "an unknown requirement token is rejected")
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X",
    requires = "accessibility", action = function() end }),
    "requires must be a list, not a bare string")
-- recommended: optional boolean; the curated Essentials starter set.
do
    local m = manifest.validate({ api = 1, id = "recd", name = "Recd", action = function() end })
    ok(m.recommended == false, "recommended defaults to false")
    local m2 = manifest.validate({ api = 1, id = "rece", name = "Rece",
        recommended = true, action = function() end })
    ok(m2.recommended == true, "recommended carried through when declared")
end
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X",
    recommended = "yes", action = function() end }), "recommended must be a boolean")
-- mnemonic: optional per-action "why this key" string; carried through the
-- single-action sugar; rejected if not a string.
do
    local m = manifest.validate({ api = 1, id = "mn", name = "Mn", action = function() end,
        mnemonic = "P for Password" })
    ok(m.actions[1].mnemonic == "P for Password", "mnemonic flows through the single-action sugar")
    local m2 = manifest.validate({ api = 1, id = "mn2", name = "Mn2",
        actions = { { id = "a", run = function() end, mnemonic = "H for History" } } })
    ok(m2.actions[1].mnemonic == "H for History", "mnemonic carried through on an actions entry")
end
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X",
    actions = { { id = "a", run = function() end, mnemonic = 42 } } }),
    "mnemonic must be a string")
local sleepDesc = desc[2]
ok(sleepDesc.kind == "service" and sleepDesc.triggerDesc == "always-on service",
    "service features described as always-on")
ok(#sleepDesc.options == 6, "sleep_schedule exports all 6 options")
ok(sleepDesc.enabled == false, "describe reflects enabled state")

-- T7b: schedule() descriptor -> describe().schedule (the Automation Timeline) ----
-- A SERVICE's internal timers are invisible to the trigger model; the schedule
-- descriptor self-reports them. Derived times must track live option values,
-- and the editable rows carry the optionKey the Timeline writes through.
do
fake.resetOpts()
fake.settings["hammerdeck.opt.sleep_schedule.sleepAt"]   = "23:30"
fake.settings["hammerdeck.opt.sleep_schedule.warn1Min"]  = 10
fake.settings["hammerdeck.opt.sleep_schedule.warn2Min"]  = 5
fake.settings["hammerdeck.opt.sleep_schedule.hardCapAt"] = "01:00"
fake.settings["hammerdeck.opt.break_reminder.workMin"]   = 30
local descS = registry.describe()
local sched = {}
for _, e in ipairs(descS) do sched[e.id] = e.schedule end
ok(type(sched.sleep_schedule) == "table" and #sched.sleep_schedule == 4,
    "sleep_schedule reports 4 schedule entries")
ok(sched.sleep_schedule[1].kind == "at" and sched.sleep_schedule[1].at == "23:20",
    "first warning derived as sleepAt - warn1Min (23:30 - 10m)")
ok(sched.sleep_schedule[2].at == "23:25", "countdown overlay derived as sleepAt - warn2Min")
ok(sched.sleep_schedule[3].at == "23:30" and sched.sleep_schedule[3].optionKey == "sleepAt",
    "force-sleep marker maps to the sleepAt option for inline edit")
ok(sched.sleep_schedule[4].at == "01:00" and sched.sleep_schedule[4].optionKey == "hardCapAt",
    "hard-cap marker maps to the hardCapAt option")
ok(sched.sleep_schedule[1].optionKey == nil, "derived warnings are advisory (no optionKey)")
ok(sched.sleep_schedule[1].category == "health", "entries inherit the feature category")
ok(type(sched.break_reminder) == "table" and sched.break_reminder[1].kind == "everyMin"
    and sched.break_reminder[1].everyMin == 30 and sched.break_reminder[1].optionKey == "workMin",
    "break_reminder reports its recurring break from the live workMin option")
ok(sched.window_switcher == nil, "a feature with no schedule descriptor reports none")

-- malformed entries are skipped, not fatal; a throwing descriptor is quarantined
package.loaded["features._sched_probe"] = {
    api = 1, id = "sched_probe", name = "Sched Probe", category = "general",
    start = function() end,
    schedule = function()
        return {
            { label = "good", everyMin = 15 },
            { label = "bad-zero", everyMin = 0 },        -- skipped (non-positive)
            { everyMin = 5 },                            -- skipped (no label)
            { label = "bad-time", at = "9999" },         -- skipped (not HH:MM)
            { label = "out-of-range", at = "25:99" },    -- skipped (shape ok, range bad)
            { label = "note only", note = "after wake" },
        }
    end,
}
registry.load("features._sched_probe")
package.loaded["features._sched_throw"] = {
    api = 1, id = "sched_throw", name = "Sched Throw",
    start = function() end,
    schedule = function() error("boom") end,
}
registry.load("features._sched_throw")
local probeSched, throwRow
for _, e in ipairs(registry.describe()) do
    if e.id == "sched_probe" then probeSched = e.schedule end
    if e.id == "sched_throw" then throwRow = e end
end
ok(type(probeSched) == "table" and #probeSched == 2,
    "malformed schedule entries are dropped, valid ones kept")
ok(probeSched[2].kind == "note" and probeSched[2].note == "after wake",
    "a note entry routes to the conditions lane")
ok(throwRow ~= nil and throwRow.schedule == nil,
    "a throwing schedule() is quarantined -- describe() still returns the row")
registry.unregister("sched_probe")
registry.unregister("sched_throw")
-- the schedule field must be a function
ok(not pcall(manifest.validate, { api = 1, id = "x", name = "X", action = function() end,
    schedule = { { label = "nope" } } }),
    "schedule must be a function, not a table")

end
-- T8: re-enable works with fresh state ------------------------------------------
do
fake.resetOpts()
-- seed our own window so the chooser has something to show -- this used to lean on
-- the fixture T3 left behind (a hidden cross-section dependency the split removed).
fake.windows = { { id = 11, title = "W", appName = "AppA", bundleID = "com.a" } }
registry.setEnabled("window_switcher", true)
fake.pressHotkey("tab")
ok(fake.visibleChooser() ~= nil, "re-enabled feature works with a fresh ctx")
registry.setEnabled("window_switcher", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after re-enable cycle")

end
-- T9: plugin quarantine -- one bad plugin must never take the platform down ----
-- (a) a missing module is recorded, not thrown
do
fake.resetOpts()
ok(registry.load("features._does_not_exist") == nil, "load returns nil for a missing module")
ok(#registry.failures().load >= 1, "missing module recorded as a load failure")

-- (b) an invalid manifest fails at register, still quarantined
package.loaded["features._bad_manifest"] = { api = 1, id = "bad_manifest", name = "Bad" } -- no action/start
ok(registry.load("features._bad_manifest") == nil, "load returns nil for an invalid manifest")

-- (c) a feature that throws inside start(ctx) -- after creating a handle -- is
--     quarantined: enable doesn't throw, the partial scope is torn down, and
--     the failure is recorded + describable.
package.loaded["features._bad_start"] = {
    api = 1, id = "bad_start", name = "Bad Start",
    start = function(ctx)
        ctx.everySeconds(5, function() end)   -- a handle BEFORE the throw
        error("boom in start")
    end,
}
ok(registry.load("features._bad_start") ~= nil, "valid manifest with a throwing start registers fine")
ok(pcall(registry.setEnabled, "bad_start", true), "enabling a broken feature does not throw")
ok(registry.failures().start["bad_start"] ~= nil, "start failure recorded")
ok(registry.liveHandleCount() == 0, "broken start's partial handle was torn down")
ok(fake.liveHandles == 0, "no native resource leaked by the broken start")

local d = registry.describe()
local badRow, sawLoadFail = nil, false
for _, e in ipairs(d) do
    if e.id == "bad_start" then badRow = e end
    if e.category == "failed" then sawLoadFail = true end
end
ok(badRow ~= nil and badRow.failed == true, "describe marks the failed feature")
ok(sawLoadFail, "describe surfaces load failures as inert rows")

-- (d) disabling clears the recorded failure
registry.setEnabled("bad_start", false)
ok(registry.failures().start["bad_start"] == nil, "disable clears the start failure")

end
-- T10: trigger rebind -- bind ANY action to ANY trigger (the core promise) -----
fake.resetOpts()

-- codec round-trips for every spec shape
local function roundtrip(spec) return triggers.decode(triggers.encode(spec)) end
local hk = roundtrip({ type = "hotkey", mods = { "cmd", "alt" }, key = "j" })
ok(hk.type == "hotkey" and hk.key == "j" and #hk.mods == 2, "hotkey codec round-trips")
ok(triggers.encode({ type = "hotkey", mods = { "cmd", "alt" }, key = "j" })
    == triggers.encode({ type = "hotkey", mods = { "alt", "cmd" }, key = "j" }),
    "hotkey encoding is canonical (mod order does not matter)")
ok(roundtrip({ type = "schedule", everyMin = 25 }).everyMin == 25, "schedule-every codec round-trips")
ok(roundtrip({ type = "schedule", at = "00:30" }).at == "00:30", "schedule-at codec round-trips")
ok(roundtrip({ type = "event", event = "wake" }).event == "wake", "event codec round-trips")
ok(triggers.decode("garbage") == nil, "decode rejects a malformed string")
ok(triggers.decode("event|bogus") == nil, "decode rejects an unknown event")

-- shared HH:MM parse: valid times parse to numbers, out-of-range/malformed reject
do
    local h, m = triggers.parseTimeOfDay("09:05")
    ok(h == 9 and m == 5, "parseTimeOfDay reads a valid HH:MM")
    local zh, zm = triggers.parseTimeOfDay("00:00")
    ok(zh == 0 and zm == 0, "parseTimeOfDay reads midnight (0 is a valid hour)")
    ok(triggers.parseTimeOfDay("29:99") == nil, "parseTimeOfDay rejects out-of-range 29:99")
    ok(triggers.parseTimeOfDay("8:5") == nil, "parseTimeOfDay rejects a 1-digit minute")
    ok(triggers.parseTimeOfDay("8") == nil, "parseTimeOfDay rejects a bare hour")
end
-- the gap the unified util closes: decode used to accept an out-of-range "at"
ok(triggers.decode("schedule|at|29:99") == nil, "decode rejects an out-of-range schedule at")
ok(triggers.decode("schedule|at|07:30").at == "07:30", "decode still accepts a valid schedule at")

-- validate rejects malformed specs
ok(not pcall(triggers.validate, { type = "hotkey" }), "validate rejects a hotkey with no key")
ok(not pcall(triggers.validate, { type = "event", event = "nope" }), "validate rejects an unknown event")
ok(not pcall(triggers.validate, { type = "schedule" }), "validate rejects a schedule with no when")
ok(not pcall(triggers.validate, { type = "schedule", at = "29:99" }),
    "validate rejects a schedule with an out-of-range at")

-- modifier NAMES are validated too (the Swift parsers used to drop an unknown
-- name silently, binding a less-modified combo); long aliases stay accepted.
ok(not pcall(triggers.validate, { type = "hotkey", mods = { "cmmd" }, key = "k" }),
    "validate rejects a hotkey with an unknown modifier")
ok(not pcall(triggers.validate, { type = "chord", mods = { "hyper" }, key = "a", follows = { "b" } }),
    "validate rejects a chord with an unknown modifier")
ok(pcall(triggers.validate, { type = "hotkey", mods = { "Command", "option" }, key = "k" }),
    "validate accepts long modifier aliases, case-insensitive")

-- the fake adapter mirrors the seam's loud token rejection (KeyModifier.swift):
-- a typo'd token errors in tests exactly like the real bridge would.
ok(not pcall(fake.adapter.bindHotkey, { "cmmd" }, "k", function() end),
    "fake bind_hotkey rejects an unknown modifier")
ok(not pcall(fake.adapter.keyStroke, { "comd" }, "v"), "fake key_stroke rejects an unknown modifier")
ok(not pcall(fake.adapter.keyStroke, { true }, "v"), "fake key_stroke rejects a non-string modifier")
ok(not pcall(fake.adapter.isModifierHeld, "atl"), "fake is_modifier_held rejects an unknown modifier")
ok(not pcall(fake.adapter.setAppearance, "drak"), "fake set_appearance rejects an unknown mode")
ok(pcall(fake.adapter.setAppearance, "toggle") and pcall(fake.adapter.setAppearance, nil),
    "fake set_appearance accepts toggle and nil (= toggle)")

-- spec -> string formatters (the verbose describe + compact glyph forms)
ok(triggers.describe(nil) == "no trigger", "describe: nil -> no trigger")
ok(triggers.describe({ type = "hotkey", mods = { "cmd", "shift" }, key = "v" })
    == "hotkey: cmd+shift+v", "describe: hotkey")
ok(triggers.describe({ type = "chord", mods = { "cmd" }, key = "a", follows = { "b", "c" } })
    == "chord: cmd+a then b c", "describe: chord")
ok(triggers.describe({ type = "schedule", everyMin = 25 }) == "schedule: every 25 min", "describe: schedule-every")
ok(triggers.describe({ type = "schedule", at = "00:30" }) == "schedule: daily at 00:30", "describe: schedule-at")
ok(triggers.describe({ type = "event", event = "wake" }) == "event: wake", "describe: event")
ok(triggers.glyph(nil) == nil, "glyph: nil -> nil")
ok(triggers.glyph({ type = "hotkey", mods = { "cmd", "shift" }, key = "v" }) == "⇧⌘V", "glyph: hotkey canonical order + upcase")
ok(triggers.glyph({ type = "hotkey", mods = { "control", "option" }, key = "left" }) == "⌃⌥←",
    "glyph: long-form mod aliases + named key")
ok(triggers.glyph({ type = "chord", mods = { "cmd" }, key = "a", follows = { "b" } }) == "⌘A B", "glyph: chord (follow keys upcased)")
ok(triggers.glyph({ type = "schedule", everyMin = 180 }) == "every 180m", "glyph: schedule-every")
ok(triggers.glyph({ type = "event", event = "wake" }) == "on wake", "glyph: event")

-- live rebind on a synthetic probe (counter action, no chooser state to manage)
local fires = 0
package.loaded["features._rebind_probe"] = {
    api = 1, id = "rebind_probe", name = "Rebind Probe",
    defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "p" },
    action = function() fires = fires + 1 end,
}
registry.load("features._rebind_probe")
registry.setEnabled("rebind_probe", true)
fake.pressHotkey("p")
ok(fires == 1, "default trigger fires the action")
ok(registry.setTrigger("rebind_probe", { type = "hotkey", mods = { "ctrl" }, key = "q" }) == true,
    "setTrigger rebinds successfully")
fake.pressHotkey("p")
ok(fires == 1, "the old hotkey no longer fires after rebind")
fake.pressHotkey("q")
ok(fires == 2, "the new hotkey fires the rebound action")
ok(fake.settings["hammerdeck.trigger.rebind_probe.main"] == "hotkey|ctrl|q",
    "the override is persisted as an encoded string (per-action key)")

-- conflict: a second enabled feature already owns ctrl+q
local fires2 = 0
package.loaded["features._rebind_other"] = {
    api = 1, id = "rebind_other", name = "Other Probe",
    defaultTrigger = { type = "hotkey", mods = { "alt" }, key = "z" },
    action = function() fires2 = fires2 + 1 end,
}
registry.load("features._rebind_other")
registry.setEnabled("rebind_other", true)
local okSet, reason = registry.setTrigger("rebind_other", { type = "hotkey", mods = { "ctrl" }, key = "q" })
ok(okSet == false and reason ~= nil, "setTrigger refuses a hotkey already taken by an enabled feature")
fake.pressHotkey("z")
ok(fires2 == 1, "the rejected rebind left the original binding intact")

-- a service has no rebindable trigger
ok(not pcall(registry.setTrigger, "sleep_schedule", { type = "event", event = "wake" }),
    "setTrigger rejects always-on service features")

-- describe exposes the editable trigger + override flag
local probeDesc
for _, d in ipairs(registry.describe()) do if d.id == "rebind_probe" then probeDesc = d end end
ok(probeDesc.actions[1].trigger and probeDesc.actions[1].trigger.key == "q",
    "describe exposes the current trigger spec")
ok(probeDesc.actions[1].triggerOverridden == true, "describe reports the override state")

-- automatable policy: schedule/event are the automated trigger types ----------
ok(triggers.isAutomated({ type = "schedule", everyMin = 5 }) == true, "schedule is automated")
ok(triggers.isAutomated({ type = "event", event = "wake" }) == true, "event is automated")
ok(triggers.isAutomated({ type = "hotkey", key = "p" }) == false, "hotkey is not automated")
ok(triggers.isAutomated({ type = "chord", key = "a", follows = { "b" } }) == false, "chord is not automated")

-- rebind_probe is the default (non-automatable): the seam refuses an automated
-- trigger but still accepts a manual one, and describe reports the flag.
ok(probeDesc.actions[1].automatable == false, "describe surfaces automatable=false by default")
local okAuto, whyAuto = registry.setTrigger("rebind_probe", { type = "schedule", everyMin = 5 })
ok(okAuto == false and whyAuto ~= nil, "seam refuses a schedule trigger on a non-automatable action")
local okAuto2 = registry.setTrigger("rebind_probe", { type = "event", event = "wake" })
ok(okAuto2 == false, "seam refuses an event trigger on a non-automatable action")

-- an automatable action accepts an automated trigger
local autoFires = 0
package.loaded["features._auto_probe"] = {
    api = 1, id = "auto_probe", name = "Auto Probe",
    actions = { { id = "main", automatable = true, run = function() autoFires = autoFires + 1 end } },
}
registry.load("features._auto_probe")
registry.setEnabled("auto_probe", true)
ok(registry.setTrigger("auto_probe", { type = "schedule", everyMin = 15 }) == true,
    "seam accepts a schedule trigger on an automatable action")
local autoDesc
for _, d in ipairs(registry.describe()) do if d.id == "auto_probe" then autoDesc = d end end
ok(autoDesc.actions[1].automatable == true, "describe surfaces automatable=true")
registry.setEnabled("auto_probe", false)
registry.unregister("auto_probe")

-- bind-on-load enforcement: a STALE stored automated override on a
-- non-automatable action (e.g. left behind after an author dropped automatable,
-- or hand-edited) must be ignored on read, not bound. rebind_probe is the
-- non-automatable hotkey probe; plant a schedule override directly in settings.
fake.settings["hammerdeck.trigger.rebind_probe.main"] = "schedule|every|5"
do
    local staleDesc
    for _, d in ipairs(registry.describe()) do if d.id == "rebind_probe" then staleDesc = d end end
    ok(staleDesc.actions[1].trigger.type == "hotkey",
        "a stale automated override on a non-automatable action is ignored (falls back to default)")
end
fake.settings["hammerdeck.trigger.rebind_probe.main"] = nil

-- clearTrigger reverts to the manifest default
registry.clearTrigger("rebind_probe")
ok(fake.settings["hammerdeck.trigger.rebind_probe.main"] == nil
    and fake.settings["hammerdeck.trigger.rebind_probe"] == nil,
    "clearTrigger removes the override")
fake.pressHotkey("p")
ok(fires == 3, "clearTrigger restored the default trigger")
fake.pressHotkey("q")
ok(fires == 3, "the override key is no longer bound after clear")

-- swapTriggers exchanges two actions' shortcuts (the Shortcut Map drag-to-swap).
-- probe is ctrl+p, other is alt+z; after the swap they trade.
local pf, of = fires, fires2
ok(registry.swapTriggers("rebind_probe", "main", "rebind_other", "main") == true,
    "swapTriggers returns true")
ok(fake.settings["hammerdeck.trigger.rebind_probe.main"] == "hotkey|alt|z",
    "probe took the other's hotkey (persisted)")
ok(fake.settings["hammerdeck.trigger.rebind_other.main"] == "hotkey|ctrl|p",
    "other took the probe's hotkey (persisted)")
fake.pressHotkey("z", { "alt" })
ok(fires == pf + 1, "after swap, probe fires on alt+z (the other's old key)")
fake.pressHotkey("p", { "ctrl" })
ok(fires2 == of + 1, "after swap, other fires on ctrl+p (the probe's old key)")
ok(fires == pf + 1, "probe no longer fires on ctrl+p")

registry.setEnabled("rebind_probe", false)
registry.setEnabled("rebind_other", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after trigger-rebind tests")

-- T11: hot reload -- re-read the catalog from disk, keep enabled-state ---------
-- Uses the real on-disk MVP modules (recorded as the catalog in T1), so the
-- package.loaded invalidation + re-require-from-disk path runs for real.
do
fake.resetOpts()
registry.setEnabled("window_switcher", true)
ok(registry.liveHandleCount() >= 1, "an enabled feature has a live binding before reload")

local summary = registry.reload()
ok(summary.count == 3, "reload re-registered exactly the catalog features")
ok(summary.failures == 0, "reload reported no load failures")
ok(registry.isEnabled("window_switcher"), "enabled-state persisted across reload")
ok(registry.liveHandleCount() >= 1, "reload re-bound the enabled feature")

-- the freshly re-required feature actually works (closure state was rebuilt)
fake.pressHotkey("tab")
ok(fake.visibleChooser() ~= nil, "feature functions after a hot reload")
fake.visibleChooser().userSelect(1)

-- a feature left disabled is registered but not bound after reload
local svcEnabled
for _, d in ipairs(registry.describe()) do
    if d.id == "sleep_schedule" then svcEnabled = d.enabled end
end
ok(svcEnabled == false, "a disabled feature stays disabled after reload")

-- the synthetic probes from T9/T10 (not in the catalog) are gone after reload
local stillHasProbe = false
for _, d in ipairs(registry.describe()) do
    if d.id == "rebind_probe" then stillHasProbe = true end
end
ok(not stillHasProbe, "non-catalog features are dropped by reload")

registry.setEnabled("window_switcher", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after hot-reload test")

end
-- T12 (display_off) migrated to test/cases/display_off.lua (RUN_LUA_SPLIT_SPEC Phase 2).
-- T13 (plain_paste) migrated to test/cases/plain_paste.lua (RUN_LUA_SPLIT_SPEC Phase 2).
-- T13c (password_generator) migrated to test/cases/password_generator.lua.
-- T13c2 (describe() localization) migrated to test/cases/_integration/describe_localization.lua.
-- (volume + media_keys were demoted from features to rules effect kinds; their
-- behavior is now covered by the effect-dispatch tests in T39.)
-- T13d (insert_datetime) migrated to test/cases/insert_datetime.lua (RUN_LUA_SPLIT_SPEC Phase 2).
-- T14: feature autodiscovery -- scan the features dir instead of a fixed list --
-- (the fake adapter exposes bare names; the real modules are on disk, so the
--  re-require path works.)
do
fake.resetOpts()
fake.featureNames = { "window_switcher", "display_off", "plain_paste", "break_reminder", "sleep_schedule" }

local discovered = registry.discover("ignored-by-fake")
ok(#discovered == 5, "discover returns one module per feature on disk")
ok(discovered[1] == "features.break_reminder", "discover sorts + prefixes module names")

-- Switch to discovery mode and reload: it re-scans and ends with exactly the
-- discovered set (this also drops the non-catalog test probes from T9/T10).
registry.setFeatureDir("ignored-by-fake")
local sum = registry.reload()
ok(sum.count == 5 and sum.failures == 0, "reload in discovery mode loads the scanned features")

-- Hot-plug: a name newly appearing in the scan shows up on the next reload;
-- one that disappears is dropped.
fake.featureNames = { "window_switcher" }
local sum2 = registry.reload()
ok(sum2.count == 1, "reload re-scans -- a removed feature folder is dropped")
ok(registry.describe()[1].id == "window_switcher", "the surviving feature is the discovered one")

ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after autodiscovery test")

end
-- T15: multi-action features -- one plugin, several shortcuts ------------------
do
fake.resetOpts()
local hits = { a = 0, b = 0 }
local starts = 0
package.loaded["features._multi"] = {
    api = 1, id = "multi", name = "Multi",
    start = function(ctx) starts = starts + 1 end,   -- service + actions combo
    actions = {
        { id = "alpha", label = "Alpha",
          defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "1" },
          run = function() hits.a = hits.a + 1 end },
        { id = "beta", label = "Beta",
          defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "2" },
          run = function() hits.b = hits.b + 1 end },
    },
}
registry.load("features._multi")
registry.setEnabled("multi", true)
ok(starts == 1, "service starts alongside its actions")
fake.pressHotkey("1"); fake.pressHotkey("2")
ok(hits.a == 1 and hits.b == 1, "both actions fire on their own hotkeys")

-- per-action rebind: siblings and the running service are untouched
ok(registry.setTrigger("multi", "beta", { type = "hotkey", mods = { "ctrl" }, key = "3" }) == true,
    "one action rebinds")
ok(starts == 1, "rebinding one action does not restart the service")
fake.pressHotkey("2")
ok(hits.b == 1, "the rebound action's old key is dead")
fake.pressHotkey("3"); fake.pressHotkey("1")
ok(hits.b == 2 and hits.a == 2, "new key fires; the sibling action is unaffected")
ok(fake.settings["hammerdeck.trigger.multi.beta"] == "hotkey|ctrl|3",
    "per-action override key persisted")

-- sibling actions cannot collide on a hotkey
local okSet2, why2 = registry.setTrigger("multi", "alpha", { type = "hotkey", mods = { "ctrl" }, key = "3" })
ok(okSet2 == false and why2 ~= nil, "sibling actions cannot share a hotkey")

-- new-shape manifest validation
rejects({ api = 1, id = "x", name = "X", action = function() end,
          actions = { { id = "a", run = function() end } } }, "action AND actions together")
rejects({ api = 1, id = "x", name = "X",
          actions = { { id = "a", run = function() end },
                      { id = "a", run = function() end } } }, "duplicate action ids")
rejects({ api = 1, id = "x", name = "X", actions = { { id = "a" } } }, "action without run")

-- describe carries per-action trigger state
local multiDesc
for _, d in ipairs(registry.describe()) do if d.id == "multi" then multiDesc = d end end
ok(#multiDesc.actions == 2 and multiDesc.actions[2].id == "beta"
    and multiDesc.actions[2].trigger.key == "3"
    and multiDesc.actions[2].triggerOverridden == true,
    "describe exports per-action trigger state")
ok(multiDesc.kind == "service" and multiDesc.triggerDesc == "always-on service",
    "service+actions still reads as a service in the list")

-- legacy stored key (pre-multi-action) is honored for single-action sugar
package.loaded["features._legacy"] = {
    api = 1, id = "legacy", name = "Legacy",
    defaultTrigger = { type = "hotkey", mods = { "ctrl" }, key = "8" },
    action = function() hits.a = hits.a + 100 end,
}
registry.load("features._legacy")
fake.settings["hammerdeck.trigger.legacy"] = "hotkey|ctrl|9"   -- old-style override
registry.setEnabled("legacy", true)
fake.pressHotkey("9")
ok(hits.a == 102, "legacy hammerdeck.trigger.<id> override is honored for sugar features")

registry.setEnabled("multi", false)
registry.setEnabled("legacy", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after multi-action tests")

end
-- T16 (count_down) migrated to test/cases/count_down.lua (RUN_LUA_SPLIT_SPEC Phase 2).
-- T17 (locate_pointer) migrated to test/cases/locate_pointer.lua (RUN_LUA_SPLIT_SPEC Phase 2).
-- T18 json decoder -> test/cases/json_codec.lua;
-- T18 bing_daily -> test/cases/bing_daily.lua (RUN_LUA_SPLIT_SPEC Phase 2).
-- T19: chord triggers -- prefix hotkey arms a follow-key sequence -------------
-- (`triggers` is the file-scope local from T10.)
fake.resetOpts()
do

-- codec round-trip: mods canonicalized (sorted), follow sequence ORDER kept
local chordEnc = triggers.encode(
    { type = "chord", mods = { "shift", "cmd" }, key = "a", follows = { "b", "c" } })
ok(chordEnc == "chord|cmd,shift|a|b,c", "chord encodes with sorted mods + ordered follows")
local chordDec = triggers.decode(chordEnc)
ok(chordDec.type == "chord" and chordDec.key == "a"
    and chordDec.follows[1] == "b" and chordDec.follows[2] == "c" and #chordDec.follows == 2,
    "chord decodes back to the same spec")
ok(triggers.decode("chord|cmd|a|") == nil, "a chord string with no follow keys decodes to nil")

-- validate rejects malformed chords
ok(pcall(triggers.validate, { type = "chord", mods = { "cmd" }, key = "a" }) == false,
    "chord without follows is rejected")
ok(pcall(triggers.validate,
    { type = "chord", mods = { "cmd" }, key = "a", follows = {} }) == false,
    "chord with empty follows is rejected")
ok(pcall(triggers.validate,
    { type = "chord", mods = { "cmd" }, key = "a", follows = { "escape" } }) == false,
    "escape cannot be a chord follow key (it always cancels)")

-- conflict semantics (the whole reason chords share prefixes)
local chordAB  = { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "b" } }
local chordAC  = { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "c" } }
local chordABC = { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "b", "c" } }
local plainA   = { type = "hotkey", mods = { "shift", "cmd" }, key = "a" }
ok(triggers.conflicts(chordAB, chordAC) == false,
    "chords sharing a prefix with distinct follows do NOT conflict")
ok(triggers.conflicts(chordAB, chordABC) == true,
    "a follow sequence that is a prefix of another (same prefix) conflicts")
ok(triggers.conflicts(chordAB, plainA) == true,
    "a plain hotkey collides with a chord's prefix combo")
ok(triggers.conflicts(plainA, { type = "hotkey", mods = { "cmd", "shift" }, key = "b" }) == false,
    "different plain hotkeys do not conflict")

-- end-to-end binding through the registry: two chords share one prefix
local chordHits = { x = 0, y = 0 }
package.loaded["features._chordy"] = {
    api = 1, id = "chordy", name = "Chordy",
    actions = {
        { id = "x", label = "X",
          defaultTrigger = { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "b" } },
          run = function() chordHits.x = chordHits.x + 1 end },
        { id = "y", label = "Y",   -- SAME prefix, different follow key
          defaultTrigger = { type = "chord", mods = { "shift", "cmd" }, key = "a", follows = { "c" } },
          run = function() chordHits.y = chordHits.y + 1 end },
    },
}
registry.load("features._chordy")
registry.setEnabled("chordy", true)
ok(fake.fireChord({ "cmd", "shift" }, "a", { "b" }) == 1, "prefix cmd+shift+a then b fires action x")
ok(chordHits.x == 1 and chordHits.y == 0, "only the matching chord ran")
ok(fake.fireChord({ "shift", "cmd" }, "a", { "c" }) == 1,
    "the sibling chord (same prefix, follow c) fires action y")
ok(chordHits.y == 1, "follow c ran action y")
ok(fake.fireChord({ "cmd", "shift" }, "a", { "z" }) == 0, "an unmatched follow fires nothing")

-- rebind a chord action to a deeper sequence; the old sequence goes dead
ok(registry.setTrigger("chordy", "x",
    { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "d", "e" } }) == true,
    "a chord action rebinds to a deeper sequence")
fake.fireChord({ "cmd", "shift" }, "a", { "b" })
ok(chordHits.x == 1, "the old chord sequence is dead after rebind")
ok(fake.fireChord({ "cmd", "shift" }, "a", { "d", "e" }) == 1, "the new (deeper) sequence fires")
ok(chordHits.x == 2, "the deeper follow sequence ran action x")
ok(fake.settings["hammerdeck.trigger.chordy.x"] == "chord|cmd,shift|a|d,e",
    "the chord override persisted encoded")

-- a chord whose follow seq is a prefix of an enabled sibling is refused
local okPrefix, whyPrefix = registry.setTrigger("chordy", "y",
    { type = "chord", mods = { "cmd", "shift" }, key = "a", follows = { "d" } })
ok(okPrefix == false and whyPrefix ~= nil, "a prefix-of-sibling chord is refused as a conflict")

-- a plain hotkey colliding with an enabled chord's prefix is refused
package.loaded["features._plain"] = {
    api = 1, id = "plain", name = "Plain",
    defaultTrigger = { type = "hotkey", mods = { "cmd", "shift" }, key = "a" },
    action = function() end,
}
registry.load("features._plain")
local okPlain, whyPlain = registry.setTrigger("plain",
    { type = "hotkey", mods = { "cmd", "shift" }, key = "a" })
ok(okPlain == false and whyPlain ~= nil, "a plain hotkey on a chord's prefix combo is refused")

registry.setEnabled("chordy", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after chord tests")

end
-- T19b: registry.hyperLegend() -- which-key legend of enabled Hyper bindings ---
do
fake.resetOpts()
package.loaded["features._hyperprobe"] = {
    api = 1, id = "hyperprobe", name = "Hyper Probe",
    actions = {
        { id = "go", label = "Go",
          defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "h" },
          run = function() end },
        { id = "no", label = "NotHyper",   -- only cmd: must be excluded
          defaultTrigger = { type = "hotkey", mods = { "cmd" }, key = "j" },
          run = function() end },
    },
}
registry.load("features._hyperprobe")
registry.setEnabled("hyperprobe", true)
local function legendHas(rows, key, label)
    for _, it in ipairs(rows) do
        if it.key == key and it.label == label then return true end
    end
    return false
end
local function legendHasLabel(rows, label)
    for _, it in ipairs(rows) do if it.label == label then return true end end
    return false
end
local legend = registry.hyperLegend()
ok(legendHas(legend, "h", "Go"), "hyperLegend lists a Hyper binding as { key, label }")
ok(not legendHasLabel(legend, "NotHyper"), "hyperLegend excludes non-Hyper bindings")
registry.setEnabled("hyperprobe", false)
ok(not legendHasLabel(registry.hyperLegend(), "Go"),
    "hyperLegend drops a disabled feature's bindings")

end
-- T20 (usage_stats live service + report.range host reporter) migrated to test/cases/usage_stats.lua (RUN_LUA_SPLIT_SPEC Phase 2).
-- T21 (Accessibility onboarding) folded into test/cases/window_switcher.lua (RUN_LUA_SPLIT_SPEC Phase 2).
-- T22 (text_actions) migrated to test/cases/text_actions.lua (RUN_LUA_SPLIT_SPEC Phase 2).
-- T23 (site_switcher) migrated to test/cases/site_switcher.lua (RUN_LUA_SPLIT_SPEC Phase 2).
-- T24 (window_snap core) + T24p (placement presets) migrated to test/cases/window_snap.lua;
-- T24b (pointer_follows_window) -> test/cases/pointer_follows_window.lua;
-- T24r (window_rewind) -> test/cases/window_rewind.lua (RUN_LUA_SPLIT_SPEC Phase 2).
-- T25 (window_modal) migrated to test/cases/window_modal.lua;
-- T25c/T25c-2/T25d/T25d2 (platform.windows geometry) -> test/cases/windows_geometry.lua;
-- T25e/T25e2 (window_grid) -> test/cases/window_grid.lua (RUN_LUA_SPLIT_SPEC Phase 2).

-- T25e/T25e-store (window_deck pure modules: identity/colors/focus/store) migrated to
--   test/cases/window_deck_pure.lua;
-- T25f (window_deck focus-driven manager) migrated to test/cases/window_deck.lua
--   (RUN_LUA_SPLIT_SPEC Phase 2).

-- T25g: no two shipped features declare COLLIDING default shortcuts ------------
-- There is no single registry of default triggers -- each feature declares its
-- own defaultTrigger in init.lua. Nothing bound them into one namespace, so a new
-- feature could silently reuse a shortcut another feature already defaults to; the
-- only check was interactive (the "already bound to X" wall a USER hits when
-- rebinding in Settings). This scans the WHOLE on-disk catalog and fails loudly on
-- any default-vs-default conflict, catching it at authoring time / CI instead.
-- (window_deck once shipped Hyper+D, already Insert Date/Time's default -- exactly
-- the class of bug this guards.) Runs on both engines (lua run.lua + test-lua.sh).
fake.resetOpts()
do
    local appdir = require("loader").appdir

    -- enumerate every feature dir that has a lua/init.lua (the shipped catalog)
    local ids = {}
    local pipe = io.popen('ls "' .. appdir .. '/features" 2>/dev/null')
    if pipe then
        for name in pipe:lines() do
            local fh = io.open(appdir .. "/features/" .. name .. "/lua/init.lua", "r")
            if fh then fh:close(); ids[#ids + 1] = name end
        end
        pipe:close()
    end
    ok(#ids >= 20, "default-trigger scan enumerated the on-disk catalog (" .. #ids .. " features)")

    -- collect every declared default hotkey/chord straight from init.lua (raw,
    -- not validated: feature.json -- the source of `name` -- is overlaid only at
    -- register time, and defaults live in init.lua regardless). Handle both the
    -- actions[] shape and the single-action sugar (top-level action+defaultTrigger).
    local defaults = {}
    local function record(id, action, t)
        if t and (t.type == "hotkey" or t.type == "chord") then
            defaults[#defaults + 1] = { feature = id, action = action, spec = t }
        end
    end
    for _, id in ipairs(ids) do
        local mod = require("features." .. id)
        if type(mod.actions) == "table" then
            for _, a in ipairs(mod.actions) do record(id, a.id or "?", a.defaultTrigger) end
        else
            record(id, "main", mod.defaultTrigger)   -- single-action sugar
        end
    end

    -- pairwise: two DIFFERENT features must not default to conflicting shortcuts
    -- (triggers.conflicts encodes the hotkey/chord-prefix rules; same-prefix chords
    -- with different follow keys are legitimately NOT a conflict).
    local clashes = {}
    for i = 1, #defaults do
        for j = i + 1, #defaults do
            local A, B = defaults[i], defaults[j]
            if A.feature ~= B.feature and triggers.conflicts(A.spec, B.spec) then
                clashes[#clashes + 1] = A.feature .. "." .. A.action
                    .. " vs " .. B.feature .. "." .. B.action
                    .. " (" .. triggers.describe(A.spec) .. ")"
            end
        end
    end
    ok(#clashes == 0,
        "no two features ship colliding default shortcuts"
        .. (#clashes > 0 and (" -- " .. table.concat(clashes, "; ")) or ""))
end

-- T26 (tab_switcher) migrated to test/cases/tab_switcher.lua (RUN_LUA_SPLIT_SPEC Phase 2).
-- T27: registry.runAction -- the menubar's quick triggers ----------------------
do
fake.resetOpts()
registry.register(require("features.plain_paste"))   -- dropped by T14's reload
registry.setEnabled("plain_paste", true)
fake.pasteboard = "  menu fired  "
ok(registry.runAction("plain_paste", "main") == true, "runAction fires an enabled action")
ok(fake.pasteboard == "menu fired", "the action really ran")
local okRun, why = registry.runAction("plain_paste", "nope")
ok(okRun == false and why:match("no action"), "unknown action refused with a reason")
registry.setEnabled("plain_paste", false)
okRun, why = registry.runAction("plain_paste", "main")
ok(okRun == false and why:match("not enabled"), "disabled feature refused")
ok(registry.runAction("ghost_feature") == false, "unknown feature refused")
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after runAction test")

end
-- T28 (clipboard_history) migrated to test/cases/clipboard_history.lua (RUN_LUA_SPLIT_SPEC Phase 2).
-- T29 (command_palette + the `commands` capability gate) migrated to
--   test/cases/command_palette.lua (RUN_LUA_SPLIT_SPEC Phase 2).
-- T30 (fire-time error surfacing: a throwing action is contained, and 3 consecutive
--   failures raise ONE alert) migrated to test/cases/_integration/fire_time_errors.lua
--   (RUN_LUA_SPLIT_SPEC).
-- T31 (modal auto-repeat: platform.modal synthesizes key-repeat from press/release edges)
--   migrated to test/cases/_integration/modal_repeat.lua;
-- T31's shortcut-advisories sub-block (triggers.advisories collision warnings) migrated to
--   test/cases/_integration/shortcut_advisories.lua (RUN_LUA_SPLIT_SPEC).
-- T32 (usage_stats report.range) folded into test/cases/usage_stats.lua (RUN_LUA_SPLIT_SPEC Phase 2).

-- T33 (manifest `page` contract: validate the shape + describe() passthrough with a
--   defaulted icon) migrated to test/cases/_integration/manifest_page.lua (RUN_LUA_SPLIT_SPEC).

-- T34: rules engine (M0) -- bind ANY trigger to ANY effect across features -----
-- The automation framework spine: a rule fires an effect (M0 effect = run a
-- feature action) on a trigger, with the same automatable context policy the
-- registry enforces per action. Pure Lua over the fake adapter.
fake.resetOpts()
do
    local rules = require("platform.rules")
    local json  = require("platform.json")

    -- An AUTOMATABLE target action (so event/schedule rules are allowed) with
    -- no defaultTrigger -- it exists only to be fired by rules.
    local ranAuto = 0
    package.loaded["features._rule_auto"] = {
        api = 1, id = "rule_auto", name = "Rule Auto",
        actions = { { id = "go", label = "Go", automatable = true,
                      run = function() ranAuto = ranAuto + 1 end } },
    }
    -- A NON-automatable target (context-dependent -- the default).
    package.loaded["features._rule_manual"] = {
        api = 1, id = "rule_manual", name = "Rule Manual",
        actions = { { id = "go", run = function() end } },
    }
    registry.load("features._rule_auto")
    registry.load("features._rule_manual")
    registry.setEnabled("rule_auto", true)
    registry.setEnabled("rule_manual", true)

    -- (a) an event rule fires the target action
    ok(rules.load({
        { id = "wake-go", on = { type = "event", event = "wake" },
          effect = { kind = "command", feature = "rule_auto", action = "go" } },
    }) == 1, "rules.load keeps a valid rule")
    rules.startAll()
    ok(rules.liveCount() == 1, "startAll bound the rule")
    fake.systemEvent("wake")
    ok(ranAuto == 1, "event rule fired the target feature's action")

    -- (b) a manual hotkey rule fires the same action
    ok(rules.load({
        { id = "hk-go", on = { type = "hotkey", mods = { "ctrl" }, key = "f13" },
          effect = { kind = "command", feature = "rule_auto", action = "go" } },
    }) == 1, "load replaces the rule set")
    rules.startAll()
    fake.systemEvent("wake")
    ok(ranAuto == 1, "the replaced (event) rule no longer fires after reload")
    fake.pressHotkey("f13", { "ctrl" })
    ok(ranAuto == 2, "hotkey rule fired the action")

    -- (c) CONTEXT POLICY: an automated trigger on a non-automatable effect is
    -- refused at load; a manual trigger on the same effect loads fine.
    local kept = rules.load({
        { id = "bad-auto", on = { type = "event", event = "wake" },
          effect = { kind = "command", feature = "rule_manual", action = "go" } },
        { id = "ok-manual", on = { type = "hotkey", mods = { "ctrl" }, key = "f14" },
          effect = { kind = "command", feature = "rule_manual", action = "go" } },
    })
    ok(kept == 1, "automated trigger on a non-automatable effect refused; manual kept")
    local ids = {}
    for _, r in ipairs(rules.all()) do ids[r.id] = true end
    ok(ids["ok-manual"] and not ids["bad-auto"],
        "the manual rule survived; the context-violating automated rule was dropped")

    -- (d) malformed rules are quarantined (no id, unknown effect kind), valid kept
    ok(rules.load({
        { id = "good", on = { type = "event", event = "wake" },
          effect = { kind = "command", feature = "rule_auto", action = "go" } },
        { on = { type = "event", event = "wake" },                       -- no id
          effect = { kind = "command", feature = "rule_auto", action = "go" } },
        { id = "badeffect", on = { type = "event", event = "wake" },
          effect = { kind = "teleport" } },                              -- unknown kind
    }) == 1, "malformed rules quarantined; the valid one is kept")

    -- (e) a rule whose target feature is DISABLED still loads, and firing it is a
    -- logged no-op (not a crash)
    registry.setEnabled("rule_auto", false)
    ok(rules.load({
        { id = "disabled-target", on = { type = "hotkey", mods = { "ctrl" }, key = "f15" },
          effect = { kind = "command", feature = "rule_auto", action = "go" } },
    }) == 1, "a rule targeting a disabled feature still loads (manual trigger)")
    rules.startAll()
    local before = ranAuto
    fake.pressHotkey("f15", { "ctrl" })
    ok(ranAuto == before, "firing a rule whose target is disabled is a no-op, not a crash")

    -- (f) loadFromSettings reads the JSON `hammerdeck.rules` key (the M4-UI source)
    registry.setEnabled("rule_auto", true)
    fake.settings["hammerdeck.rules"] = json.encode({
        { id = "from-settings", on = { type = "event", event = "wake" },
          effect = { kind = "command", feature = "rule_auto", action = "go" } },
    })
    ok(rules.loadFromSettings() == 1, "loadFromSettings decodes + loads the rules JSON setting")
    rules.startAll()
    before = ranAuto
    fake.systemEvent("wake")
    ok(ranAuto == before + 1, "a rule loaded from settings fires")
    fake.settings["hammerdeck.rules"] = nil

    -- (g) teardown leaks nothing
    rules.stopAll()
    ok(rules.liveCount() == 0, "stopAll unbound every rule")
    rules.load({})
    ok(rules.count() == 0, "rules.load({}) clears the set")

    registry.setEnabled("rule_auto", false)
    registry.setEnabled("rule_manual", false)
    registry.unregister("rule_auto")
    registry.unregister("rule_manual")
    ok(fake.liveHandles == 0, "no native handle leaked across the rules engine tests")
end

-- T35: rules engine (M1) -- state-signal triggers, notify effect, mutation API --
-- The condition/state half of the framework: a rule fires on a STATE SIGNAL
-- crossing a value (frontmostApp becomes/leaves), the observable `notify` effect,
-- and the add/setEnabled/remove + describe surface the Settings Rules tab calls.
fake.resetOpts()
do
    local rules   = require("platform.rules")
    local effects = require("platform.effects")
    local json    = require("platform.json")

    -- (a) a `state` trigger fires on the enter transition, not on stay/leave
    fake.frontmost = "Finder"
    local nB = #fake.notifications
    ok(rules.load({
        { id = "safari-front",
          on = { type = "state", signal = "frontmostApp", becomes = "Safari" },
          effect = { kind = "notify", title = "HD", text = "Safari front" } },
    }) == 1, "state-trigger rule with a notify effect loads (notify is context-free)")
    rules.startAll()
    ok(rules.liveCount() == 1, "state rule bound")
    fake.activateApp("Mail")
    ok(#fake.notifications == nB, "switching to a non-target app does not fire")
    fake.activateApp("Safari")
    ok(#fake.notifications == nB + 1, "frontmost BECOMES Safari -> notify fires (enter)")
    fake.activateApp("Safari")
    ok(#fake.notifications == nB + 1, "re-activating Safari (no value change) does not re-fire")
    fake.activateApp("Notes")
    ok(#fake.notifications == nB + 1, "leaving Safari does not fire a 'becomes' rule")

    -- (b) a `leaves` trigger fires on the exit transition, not on enter
    rules.load({
        { id = "safari-leave",
          on = { type = "state", signal = "frontmostApp", leaves = "Safari" },
          effect = { kind = "notify", title = "HD", text = "left Safari" } },
    })
    rules.startAll()
    local nL = #fake.notifications
    fake.activateApp("Safari")
    ok(#fake.notifications == nL, "a 'leaves' rule does not fire on enter")
    fake.activateApp("Mail")
    ok(#fake.notifications == nL + 1, "frontmost LEAVES Safari -> notify fires (exit)")

    -- (c) context policy: a state trigger (automated) cannot run a non-automatable command
    package.loaded["features._m1_manual"] = {
        api = 1, id = "m1_manual", name = "M1 Manual",
        actions = { { id = "go", run = function() end } },
    }
    registry.load("features._m1_manual"); registry.setEnabled("m1_manual", true)
    ok(rules.load({
        { id = "bad", on = { type = "state", signal = "frontmostApp", becomes = "X" },
          effect = { kind = "command", feature = "m1_manual", action = "go" } },
    }) == 0, "state trigger on a non-automatable command is refused (context policy)")

    -- (d) an unknown signal is refused
    ok(rules.load({
        { id = "badsig", on = { type = "state", signal = "ghost", becomes = "X" },
          effect = { kind = "notify", title = "x" } },
    }) == 0, "a rule on an unknown signal is refused")

    -- (e) mutation API + persistence + describe (the UI surface)
    local ran = 0
    package.loaded["features._m1_auto"] = {
        api = 1, id = "m1_auto", name = "M1 Auto",
        actions = { { id = "go", automatable = true, run = function() ran = ran + 1 end } },
    }
    registry.load("features._m1_auto"); registry.setEnabled("m1_auto", true)
    fake.settings["hammerdeck.rules"] = nil
    rules.load({})
    local okAdd, rid = rules.add({ on = { type = "event", event = "wake" },
        effect = { kind = "command", feature = "m1_auto", action = "go" } })
    ok(okAdd and type(rid) == "string", "add() assigns an id and returns it")
    ok(rules.count() == 1 and rules.liveCount() == 1, "added rule is loaded + bound")
    ok(type(fake.settings["hammerdeck.rules"]) == "string", "add() persisted to hammerdeck.rules")
    local persisted = json.decode(fake.settings["hammerdeck.rules"])
    ok(type(persisted) == "table" and persisted[1].id == rid, "persisted JSON carries the rule")

    local d = rules.describe()
    ok(#d == 1 and d[1].id == rid and d[1].enabled == true
        and d[1].triggerDesc:find("wake") and d[1].effectDesc:find("Run M1 Auto"),
        "describe() yields {id, enabled, triggerDesc, effectDesc} for the UI")
    -- the command effect names the action by its friendly "Do"-dropdown label
    -- (the feature name for a sole action), not the raw "m1_auto.go" id.
    ok(effects.describe({ kind = "command", feature = "m1_auto", action = "go" }) == "Run M1 Auto",
        "describe command uses the friendly action label")
    -- fallback: an unloaded/parked feature's command shows the raw ids (no blank)
    ok(effects.describe({ kind = "command", feature = "ghost", action = "x" }) == "Run ghost.x",
        "describe command falls back to raw ids when the feature isn't loaded")
    -- fallback: a LOADED feature but an unknown action (a stale rule whose action
    -- was renamed/removed) -- resolveAction fails -> raw ids, not a blank
    ok(effects.describe({ kind = "command", feature = "m1_auto", action = "bogus" }) == "Run m1_auto.bogus",
        "describe command falls back to raw ids for an unknown action on a loaded feature")

    local logsBefore = #fake.logs
    fake.systemEvent("wake")
    ok(ran == 1, "the added rule fires")
    local sawFireLog = false
    for i = logsBefore + 1, #fake.logs do
        if fake.logs[i]:find("fired") then sawFireLog = true end
    end
    ok(sawFireLog, "a fired rule logs a diagnostic trace (so silent no-fires are debuggable)")
    ok(rules.setEnabled(rid, false) == true, "setEnabled(false) succeeds")
    ok(rules.count() == 1 and rules.liveCount() == 0, "a disabled rule stays loaded but unbound")
    fake.systemEvent("wake")
    ok(ran == 1, "a disabled rule does not fire")
    ok(rules.setEnabled(rid, true) == true, "setEnabled(true) re-binds")
    fake.systemEvent("wake")
    ok(ran == 2, "the re-enabled rule fires again")

    -- update in place: keep the id, change the effect (the UI "Save changes")
    ok(rules.update(rid, { on = { type = "event", event = "wake" },
        effect = { kind = "notify", title = "updated" } }) == true,
        "update() replaces a rule's spec in place")
    local du = rules.describe()
    ok(#du == 1 and du[1].id == rid and du[1].effectDesc:find("updated") ~= nil,
        "update kept the id and changed the effect")
    ok(du[1].on ~= nil and du[1].effect ~= nil,
        "describe() carries the raw on/effect spec (so the edit form can pre-fill)")
    -- the context policy is enforced on update too, not just add
    ok(rules.update(rid, { on = { type = "state", signal = "frontmostApp", becomes = "X" },
        effect = { kind = "command", feature = "m1_manual", action = "go" } }) == false,
        "update() refuses a context-violating change (policy enforced on edit)")

    -- (e2) advanced "Edit as JSON": specJSON exposes one rule's full stored spec,
    -- and updateJSON round-trips it -- including fields the guided form can't build
    -- (a placement's titlePattern). Bad input is refused with a reason, never thrown.
    local sj = rules.specJSON(rid)
    ok(type(sj) == "string" and json.decode(sj).id == rid,
        "specJSON returns the rule's full spec as JSON")
    ok(select(1, rules.specJSON("nope")) == nil, "specJSON(unknown id) returns nil + reason")
    ok(rules.updateJSON(rid, '{"on":{"type":"event","event":"sleep"},'
        .. '"effect":{"kind":"layout","placements":[{"app":"Safari",'
        .. '"titlePattern":"Docs","screen":"DELL","pos":"left"}]}}') == true,
        "updateJSON accepts a spec with a placement titlePattern (the advanced field)")
    ok(rules.describe()[1].effect.placements[1].titlePattern == "Docs",
        "the titlePattern survived the JSON round-trip into the stored spec")
    ok(select(1, rules.updateJSON(rid, "{not json")) == false,
        "updateJSON refuses malformed JSON with a reason (no crash)")
    ok(select(1, rules.updateJSON(rid, '{"on":{"type":"event","event":"wake"},'
        .. '"effect":{"kind":"layout","placements":[{"app":"Safari",'
        .. '"titlePattern":123,"screen":"DELL","pos":"left"}]}}')) == false,
        "updateJSON rejects a non-string titlePattern (validate guards the advanced path)")

    ok(rules.remove(rid) == true and rules.count() == 0, "remove() drops the rule")

    -- (f) formOptions feeds the Add form's dropdowns
    local fo = rules.formOptions()
    local sawFrontmost = false
    for _, s in ipairs(fo.signals) do if s == "frontmostApp" then sawFrontmost = true end end
    ok(type(fo.signals) == "table" and sawFrontmost, "formOptions lists the available signals")
    local sawNotify = false
    for _, e in ipairs(fo.effects) do if e.kind == "notify" then sawNotify = true end end
    ok(sawNotify, "formOptions offers the notify effect")

    -- (g) rule NAMES + the on-demand "Test" (rules.fire) ----------------------
    -- Wrapped in a nested do...end so its locals release before the block's tail
    -- (Lua caps a function at 200 locals; this big T35 block runs close).
    do
        rules.load({})
        local okN, nid = rules.add({ name = "Dock at desk",
            on = { type = "event", event = "wake" },
            effect = { kind = "notify", title = "HD", text = "docked" } })
        ok(okN, "add() accepts an optional rule name")
        ok(rules.describe()[1].name == "Dock at desk", "describe() surfaces the rule name")

        -- describe() also carries the plain-English sentence -- the same read-back the
        -- editor's Name placeholder shows, so an unnamed rule lists AS that sentence.
        local specs = rules.all()
        local d1 = rules.describe()[1]
        ok(#specs >= 1 and #d1.sentence > 0 and d1.sentence == rules.sentence(specs[1]),
            "describe() carries the read-back sentence (the list shows it for unnamed rules)")

        -- an UNNAMED rule reports name == "" -- the fallback the list row leans on
        -- (it shows the trigger text when the name is blank, never a nil/"rule2").
        local _, nid2 = rules.add({ on = { type = "event", event = "wake" },
            effect = { kind = "notify", title = "HD" } })
        local unnamed
        for _, r in ipairs(rules.describe()) do if r.id == nid2 then unnamed = r end end
        ok(unnamed ~= nil and unnamed.name == "", "an unnamed rule reports name == \"\" (list-row fallback)")
        rules.remove(nid2)

        -- fire() runs the effect ON DEMAND, bypassing the trigger (the Test button)
        local nF = #fake.notifications
        local fOk, fNote = rules.fire(nid)
        ok(fOk == true and #fake.notifications == nF + 1,
            "fire() runs the effect on demand -- no trigger needed")
        ok(fNote == nil or fNote == "", "a clean fire returns no partial-success note")

        -- a manual test tags the log [test] so it never reads like a real trigger fire
        local taggedTest = false
        for i = 1, #fake.logs do if fake.logs[i]:find("%[test%]") then taggedTest = true end end
        ok(taggedTest, "fire() tags its log trace as a manual [test]")

        -- fire() tests a DISABLED rule too (you verify the effect, not the binding)
        rules.setEnabled(nid, false)
        local nD = #fake.notifications
        ok(select(1, rules.fire(nid)) == true and #fake.notifications == nD + 1,
            "fire() tests a disabled rule (verify the effect before enabling it)")

        ok(select(1, rules.fire("nope")) == false, "fire(unknown id) returns false + reason")

        -- a non-string name is refused by validate (guards the JSON path too)
        ok(select(1, rules.add({ name = 123,
            on = { type = "event", event = "wake" },
            effect = { kind = "notify", title = "x" } })) == false,
            "add() rejects a non-string name")

        -- a state trigger with an empty/non-string value is refused -- it would
        -- otherwise bind happily and silently NEVER fire (sig.match never matches
        -- "" or a number against a string-valued signal). The form blocks an empty
        -- value, but the JSON authoring path needs this engine-side backstop.
        ok(select(1, rules.add({ on = { type = "state", signal = "frontmostApp", becomes = "" },
            effect = { kind = "notify", title = "x" } })) == false,
            "add() rejects a state trigger with an empty value (silent-dead-rule guard)")
        ok(select(1, rules.add({ on = { type = "state", signal = "frontmostApp", becomes = 5 },
            effect = { kind = "notify", title = "x" } })) == false,
            "add() rejects a non-string state trigger value")

        -- a daily-at schedule must be a REAL clock time: "29:79" matched the old
        -- HH:MM regex but could never fire correctly -- now range-checked.
        ok(select(1, rules.add({ on = { type = "schedule", at = "29:79" },
            effect = { kind = "notify", title = "x" } })) == false,
            "add() rejects an out-of-range daily-at time (29:79)")
        ok(rules.add({ on = { type = "schedule", at = "23:59" },
            effect = { kind = "notify", title = "x" } }) == true,
            "add() still accepts a valid edge time (23:59)")
    end

    -- cleanup
    rules.load({})
    fake.settings["hammerdeck.rules"] = nil
    registry.setEnabled("m1_manual", false); registry.unregister("m1_manual")
    registry.setEnabled("m1_auto", false); registry.unregister("m1_auto")
    ok(fake.liveHandles == 0, "no native handle leaked across the M1 rules tests")
end

-- T35a-P10: a rule whose effect keeps FAILING raises ONE visible alert after 3
-- consecutive REAL fires (the directly-bound automated path already does this via
-- registry.FAIL_ALERT_AFTER; rules now mirror it, keyed per RULE). Manual "Test"
-- fires don't count toward the streak, and a success resets it -- so a scheduled
-- rule silently dying surfaces, without per-effect popup spam.
fake.resetOpts()
do
    local rules = require("platform.rules")
    -- An automatable action that throws on demand (toggle `boom` to make it succeed).
    local boom = true
    package.loaded["features._m1_fail"] = {
        api = 1, id = "m1_fail", name = "M1 Fail",
        actions = { { id = "boom", automatable = true,
                      run = function() if boom then error("kaboom") end end } },
    }
    registry.load("features._m1_fail"); registry.setEnabled("m1_fail", true)

    fake.frontmost = "Finder"
    ok(rules.load({
        { id = "flaky", name = "Flaky rule",
          on = { type = "state", signal = "frontmostApp", becomes = "Zoom" },
          effect = { kind = "command", feature = "m1_fail", action = "boom" } },
    }) == 1, "a rule on an automatable (but throwing) command loads")
    rules.startAll()
    ok(rules.liveCount() == 1, "failing-effect rule bound")

    -- Drive exactly one REAL fire (enter Zoom from elsewhere).
    local function enterZoom()
        fake.activateApp("Finder")   -- leave Zoom (a `becomes` rule does not fire on leave)
        fake.activateApp("Zoom")     -- enter -> one real fire
    end

    local aB = #fake.alerts
    enterZoom()
    ok(#fake.alerts == aB, "1st real failure: logged, no alert yet")
    enterZoom()
    ok(#fake.alerts == aB, "2nd real failure: still no alert")
    -- A manual Test fire fails too, but must NOT advance the streak.
    rules.fire("flaky")
    ok(#fake.alerts == aB, "a failing manual Test fire does not count toward the streak")
    enterZoom()
    ok(#fake.alerts == aB + 1, "3rd consecutive REAL failure raises exactly one alert")
    ok(fake.alerts[#fake.alerts]:find("Flaky rule", 1, true)
        and fake.alerts[#fake.alerts]:find("keeps failing", 1, true),
        "the alert names the rule and says it keeps failing")
    enterZoom()
    ok(#fake.alerts == aB + 1, "further failures stay quiet -- no popup spam")

    -- A SUCCESS clears the streak: it then takes 3 fresh failures to alert again.
    boom = false
    enterZoom()
    ok(#fake.alerts == aB + 1, "a successful fire raises no alert (and clears the streak)")
    boom = true
    enterZoom(); enterZoom()
    ok(#fake.alerts == aB + 1, "two failures after the reset: below threshold, still quiet")
    enterZoom()
    ok(#fake.alerts == aB + 2, "streak restarted post-success -> 3 more failures, one new alert")

    -- cleanup
    rules.load({})
    registry.setEnabled("m1_fail", false); registry.unregister("m1_fail")
    ok(fake.liveHandles == 0, "no native handle leaked across the P10 fail-alert test")
end

-- T35b: frontmostApp matches by BUNDLE ID when the rule carries `on.bundleId` -- so a
-- rule keyed to an app fires regardless of the app's localized name (locale / rename),
-- and a DIFFERENT app that merely shares the display name does NOT. A rule with no
-- bundle id (free-typed) still matches by name. Exercises the real signal value
-- ({name, bundleId}) + rules.bindOne's bundle-id-first target + sig.match.
fake.resetOpts()
do
    local rules   = require("platform.rules")
    local effects = require("platform.effects")
    fake.settings["hammerdeck.rules"] = nil
    fake.frontmost = "Finder"; fake.frontmostId = "com.apple.finder"

    -- (a) bundle-id rule: becomes = display name, bundleId = the stable match key
    rules.load({
        { id = "slack-front",
          on = { type = "state", signal = "frontmostApp", becomes = "Slack",
                 bundleId = "com.tinyspeck.slackmacgap" },
          effect = { kind = "notify", title = "HD", text = "Slack front" } },
    })
    rules.startAll()
    local nB = #fake.notifications
    -- the app reports a DIFFERENT localized name but the matching bundle id -> fires
    fake.activateApp("Slack (Beta)", "com.tinyspeck.slackmacgap")
    ok(#fake.notifications == nB + 1,
        "frontmostApp matches by bundle id despite a different localized name")

    -- a same-NAME app of a DIFFERENT bundle does not fire (bundle id is authoritative)
    fake.activateApp("Finder", "com.apple.finder")   -- leave -> reset the edge
    local nB2 = #fake.notifications
    fake.activateApp("Slack", "com.other.slackclone")
    ok(#fake.notifications == nB2,
        "a same-named app of a different bundle does not fire a bundle-id rule")

    -- (b) a free-typed rule (no bundleId) still matches by name
    rules.load({
        { id = "notes-front",
          on = { type = "state", signal = "frontmostApp", becomes = "Notes" },
          effect = { kind = "notify", title = "HD", text = "Notes" } },
    })
    rules.startAll()
    local nN = #fake.notifications
    fake.activateApp("Notes", "com.apple.Notes")
    ok(#fake.notifications == nN + 1, "a rule with no bundle id matches by name (free-text)")

    -- (c) the engine IGNORES a stray on.bundleId on a signal that doesn't support it
    -- (sig.bundleIdMatch=false) -- so a hand-authored JSON rule (or a stale id left by
    -- switching signals in the form) on an enum/name/set signal still fires by its real
    -- value, instead of matching a bundle id it never satisfies (a silent dead rule).
    fake.appearance = "light"
    rules.load({
        { id = "appdark",
          on = { type = "state", signal = "appearance", becomes = "dark", bundleId = "com.stray.id" },
          effect = { kind = "notify", title = "Dark" } },
    })
    rules.startAll()
    local nD = #fake.notifications
    fake.appearance = "dark"; fake.systemEvent("appearanceChanged")
    ok(#fake.notifications == nD + 1,
        "a stray on.bundleId on a non-app signal is ignored -- the rule fires by its value, not dead")

    -- (d) from-trigger (@trigger:app) on a bundle-id rule resolves to the BUNDLE ID, so
    -- the effect finds the running app even when its localized name has drifted from the
    -- name the rule was authored with -- the case bundle-id matching exists for.
    rules.load({
        { id = "min-front",
          on = { type = "state", signal = "frontmostApp", becomes = "Slack",
                 bundleId = "com.tinyspeck.slackmacgap" },
          effect = { kind = "minimizeApp", app = effects.TRIGGER_APP } },
    })
    rules.startAll()
    local nMin = #fake.minimized
    fake.activateApp("Slack (Renamed)", "com.tinyspeck.slackmacgap")
    ok(#fake.minimized == nMin + 1 and fake.minimized[#fake.minimized] == "com.tinyspeck.slackmacgap",
        "from-trigger @trigger:app on a bundle-id rule passes the BUNDLE ID to the effect")

    rules.load({}); fake.frontmost = nil; fake.frontmostId = ""; fake.appearance = "light"
end

-- T35p: PARKING -- a stored rule whose target is absent THIS boot (a renamed/gone
-- signal or feature) is PRESERVED + surfaced as "unavailable", never silently
-- deleted on the next mutation, and re-activates when its target returns ----------
fake.resetOpts()
do
    local rules = require("platform.rules")
    fake.settings["hammerdeck.rules"] = nil

    -- reason attribution: a rule with a gone signal AND a command effect blames the
    -- SIGNAL (the verifiable cause), not the feature -- the parkReason ordering.
    rules.load({ { id = "both", on = { type = "state", signal = "ghostSignal", becomes = "X" },
        effect = { kind = "command", feature = "whatever", action = "go" } } })
    local both
    for _, r in ipairs(rules.describe()) do if r.id == "both" then both = r end end
    ok(both ~= nil and both.reason:find("ghostSignal", 1, true) ~= nil,
        "a gone-signal + command rule blames the signal, not the feature")

    -- one valid rule + one referencing a signal that no longer exists (same failure
    -- shape as a feature renamed/removed across an app update).
    local kept = rules.load({
        { id = "good",  on = { type = "event", event = "wake" },
          effect = { kind = "notify", title = "ok" } },
        { id = "ghost", on = { type = "state", signal = "ghostSignal", becomes = "X" },
          effect = { kind = "notify", title = "z" } },
    })
    ok(kept == 1, "load keeps the valid rule and PARKS the unavailable one (count excludes it)")
    rules.startAll()
    ok(rules.liveCount() == 1, "a parked rule is not bound")

    -- the parked rule is SURFACED (greyed/unavailable), not vanished
    local ghost
    for _, r in ipairs(rules.describe()) do if r.id == "ghost" then ghost = r end end
    ok(ghost ~= nil and ghost.unavailable == true, "describe() surfaces the parked rule as unavailable")
    ok(type(ghost.reason) == "string" and ghost.reason:find("ghostSignal", 1, true) ~= nil,
        "the unavailable reason names the missing target")

    -- THE BUG: a mutation must NOT erase the parked rule. setEnabled persists, then
    -- a fresh load from settings must still find BOTH.
    rules.setEnabled("good", false)
    rules.loadFromSettings()
    local stillGhost = false
    for _, r in ipairs(rules.describe()) do if r.id == "ghost" then stillGhost = true end end
    ok(stillGhost, "a mutation re-persists the parked rule -- it is NOT silently deleted")

    -- a parked rule is deletable
    ok(rules.remove("ghost") == true, "a parked rule can be removed")
    local gone = true
    for _, r in ipairs(rules.describe()) do if r.id == "ghost" then gone = false end end
    ok(gone, "removing a parked rule drops it from the list")

    -- editing a parked rule's JSON to a VALID spec un-parks it into the live set
    rules.load({
        { id = "fix", on = { type = "state", signal = "ghostSignal", becomes = "X" },
          effect = { kind = "notify", title = "z" } },
    })
    ok(rules.count() == 0 and select(1, rules.specJSON("fix")) ~= nil,
        "a parked rule is editable (specJSON returns it) though count excludes it")
    ok(rules.update("fix", { on = { type = "event", event = "wake" },
        effect = { kind = "notify", title = "z" } }) == true,
        "updating a parked rule to a valid spec succeeds (un-parks)")
    ok(rules.count() == 1, "the fixed rule un-parks into the live set")
    local fixed
    for _, r in ipairs(rules.describe()) do if r.id == "fix" then fixed = r end end
    ok(fixed ~= nil and fixed.unavailable ~= true, "the un-parked rule is now a normal live rule")

    -- cleanup
    rules.stopAll()
    rules.load({})
    fake.settings["hammerdeck.rules"] = nil
    ok(fake.liveHandles == 0, "no native handle leaked across the parking tests")
end

-- T35f: per-rule FIRE STATUS -- describe() reports when a rule last fired, whether
-- it was a Test, and whether the effect succeeded, so a silently-dead rule shows --
fake.resetOpts()
do
    local rules = require("platform.rules")
    fake.settings["hammerdeck.rules"] = nil
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
    fake.windows = {}

    local function row(rid)
        for _, r in ipairs(rules.describe()) do if r.id == rid then return r end end
    end

    rules.load({})
    local _, nid = rules.add({ on = { type = "event", event = "wake" },
        effect = { kind = "notify", title = "hi" } })
    rules.startAll()
    ok(row(nid).lastFired == nil, "a fresh rule reports no last-fired time (not fired yet)")

    -- a REAL trigger fire stamps lastFired -- not a test, effect succeeded
    fake.systemEvent("wake")
    local r1 = row(nid)
    ok(type(r1.lastFired) == "number" and r1.lastFiredTest ~= true and r1.lastFiredOk == true,
        "a real trigger fire records lastFired (via trigger, ok)")

    -- a TEST fire is tagged so the UI can say 'tested' not 'fired'
    rules.fire(nid)
    ok(row(nid).lastFiredTest == true, "a Test fire is tagged lastFiredTest")

    -- editing a rule clears its fire history (the old fire no longer describes it)
    rules.update(nid, { on = { type = "event", event = "wake" },
        effect = { kind = "notify", title = "changed" } })
    ok(row(nid).lastFired == nil, "update() clears the fire history (behavior changed)")

    -- a FAILED effect (layout with no present display) records lastFiredOk = false
    local _, lid = rules.add({ on = { type = "event", event = "wake" },
        effect = { kind = "layout", placements = { { app = "X", screen = "Ghost", pos = "full" } } } })
    rules.startAll()
    fake.systemEvent("wake")
    ok(row(lid).lastFiredOk == false, "a failed effect records lastFiredOk = false")

    -- removing a rule drops its fire history; a fresh load clears it all
    rules.remove(nid)
    ok(row(nid) == nil, "a removed rule leaves no row")
    rules.load({ { id = nid, on = { type = "event", event = "wake" },
        effect = { kind = "notify", title = "hi" } } })
    ok(row(nid).lastFired == nil, "load() clears the fire history (a fresh session)")

    -- cleanup
    rules.stopAll()
    rules.load({})
    fake.settings["hammerdeck.rules"] = nil
    fake.windows = {}
    ok(fake.liveHandles == 0, "no native handle leaked across the fire-status tests")
end

-- T36: window-layout effect (M2) -- place windows on named displays, self-gating,
-- capture-current-arrangement, and the screenChanged -> layout pipeline ---------
-- The seed automation: an external monitor connects (screenChanged) and assigned
-- apps snap to assigned rects on assigned displays. A layout placement is
-- SELF-GATING -- it targets a display by name, so it no-ops when that monitor is
-- unplugged, which is why a coarse screenChanged trigger is enough.
fake.resetOpts()
do
    local effects = require("platform.effects")
    local rules   = require("platform.rules")
    local W       = require("platform.windows")
    local json    = require("platform.json")

    local function approx(a, b) return type(a) == "number" and math.abs(a - b) < 1e-6 end

    -- Two displays: the laptop (primary) + an external to its right.
    fake.screenList = {
        { x = 0,    y = 0, w = 1440, h = 900,  name = "Built-in", index = 1, builtin = true },
        { x = 1440, y = 0, w = 2560, h = 1440, name = "DELL",     index = 2 },
    }
    fake.windows = {
        { id = 1, appName = "Safari", title = "Safari",   x = 100,  y = 100, w = 400, h = 300 },
        { id = 2, appName = "Code",   title = "main.lua", x = 1500, y = 100, w = 800, h = 600 },
    }

    -- (a) layout effects are context-free + validated
    ok(effects.requiresContext({ kind = "layout", placements = {} }) == false,
        "a layout effect is context-free (safe on automated triggers)")
    local okV = pcall(effects.validate, { kind = "layout", placements = {} })
    ok(okV == false, "validate rejects a layout with no placements")
    okV = pcall(effects.validate, { kind = "layout",
        placements = { { app = "Safari", screen = "DELL", pos = "nope" } } })
    ok(okV == false, "validate rejects a placement with an unknown position")

    -- (b) dispatch places each matching window on its named display's rect
    local layout = { kind = "layout", placements = {
        { app = "Safari", screen = "Built-in", pos = "left" },  -- left half of laptop
        { app = "Code",   screen = "DELL",     pos = "full" },  -- fill the external
    } }
    ok(select(1, effects.dispatch(layout)) == true, "layout dispatch reports success")
    ok(#fake.windowFrameSets == 2, "both matching windows were moved")
    local s1 = fake.windowFrameSets[1]
    ok(s1.id == 1 and approx(s1.x, 0) and approx(s1.y, 0) and approx(s1.w, 720) and approx(s1.h, 900),
        "Safari snapped to the left half of the Built-in display")
    local s2 = fake.windowFrameSets[2]
    ok(s2.id == 2 and approx(s2.x, 1440) and approx(s2.y, 0) and approx(s2.w, 2560) and approx(s2.h, 1440),
        "Code filled the DELL display (offset by its origin)")

    -- (b2) titlePattern picks ONE of several same-app windows (the advanced
    -- disambiguator -- two Safari windows, only the "Docs" one moves)
    fake.windows = {
        { id = 11, appName = "Safari", title = "Gmail - Inbox",  x = 5,  y = 5, w = 50, h = 50 },
        { id = 12, appName = "Safari", title = "Docs - report",  x = 60, y = 5, w = 50, h = 50 },
    }
    fake.windowFrameSets = {}
    ok(W.windowMatches(fake.windows[2], { app = "Safari", titlePattern = "Docs" }) == true
        and W.windowMatches(fake.windows[1], { app = "Safari", titlePattern = "Docs" }) == false,
        "windowMatches honors titlePattern (plain substring of the title)")
    ok(W.windowMatches(fake.windows[2], { app = "Safari", titlePattern = "docs" }) == true,
        "titlePattern is case-insensitive ('docs' matches 'Docs - report')")
    local okT = effects.dispatch({ kind = "layout", placements = {
        { app = "Safari", titlePattern = "Docs", screen = "DELL", pos = "full" } } })
    ok(okT == true and #fake.windowFrameSets == 1 and fake.windowFrameSets[1].id == 12,
        "a layout placement with titlePattern moves only the matching same-app window")

    -- (b3) PARTIAL miss: a present-display placement whose app is closed doesn't
    -- silently vanish -- dispatch still succeeds (some moved) but returns a note
    -- naming the unmatched placement, so a half-firing rule is debuggable.
    -- (scoped in do...end -- these locals would otherwise push the big T36 block
    -- past Lua's 200-locals-per-function limit)
    do
    fake.windowFrameSets = {}
    local okP, note = effects.dispatch({ kind = "layout", placements = {
        { app = "Safari", screen = "DELL", pos = "left" },   -- present + matches
        { app = "Mail",   screen = "DELL", pos = "right" },  -- present, but Mail is closed
    } })
    ok(okP == true and #fake.windowFrameSets == 1, "a partial layout still moves the windows it can")
    ok(type(note) == "string" and note:find("1/2", 1, true) and note:find("Mail", 1, true),
        "a partial fire returns a note naming the unmatched placement (moved 1/2 -- no window for Mail)")
    -- a placement on an ABSENT display is NOT counted as a miss (self-gating, silent)
    fake.windowFrameSets = {}
    local okG, noteG = effects.dispatch({ kind = "layout", placements = {
        { app = "Safari", screen = "DELL",        pos = "left" },   -- present, matches
        { app = "Mail",   screen = "Thunderbolt", pos = "right" },  -- display absent -> self-gated
    } })
    ok(okG == true and noteG == nil, "an absent-display placement self-gates silently (not a partial-miss note)")
    -- self-gated placements don't inflate the denominator (only 1 present display)
    fake.windowFrameSets = {}
    local okD2, noteD2 = effects.dispatch({ kind = "layout", placements = {
        { app = "Safari", screen = "DELL",        pos = "left" },   -- present, matches
        { app = "Mail",   screen = "DELL",        pos = "right" },  -- present, no Mail window
        { app = "Notes",  screen = "Thunderbolt", pos = "full" },   -- absent -> self-gated
    } })
    ok(okD2 == true and noteD2:find("1/2", 1, true) ~= nil and noteD2:find("3", 1, true) == nil,
        "the partial-fire denominator counts only present-display placements (1/2, not 1/3)")

    -- (b4) matched-but-move-FAILED: the window is found but the AX move is refused
    -- -- surfaced in the note, never a silent "fired"
    fake.windows = {
        { id = 21, appName = "Safari", title = "ok",   x = 5,  y = 5, w = 50, h = 50 },
        { id = 22, appName = "Code",   title = "stuck", x = 60, y = 5, w = 50, h = 50 },
    }
    fake.windowFrameSets = {}
    fake.failWindowFrameIds = { [22] = true }
    local okF, noteF = effects.dispatch({ kind = "layout", placements = {
        { app = "Safari", screen = "DELL", pos = "left" },   -- moves
        { app = "Code",   screen = "DELL", pos = "right" },  -- matches but move fails
    } })
    ok(okF == true and #fake.windowFrameSets == 1, "the movable window still moves")
    ok(type(noteF) == "string" and noteF:find("move failed", 1, true) and noteF:find("Code", 1, true),
        "a matched-but-move-failed placement is surfaced (not silently dropped)")
    -- every move failing -> reports failure with the accurate reason (not 'no matching windows')
    fake.windowFrameSets = {}
    fake.failWindowFrameIds = { [21] = true }
    local okZ, reasonZ = effects.dispatch({ kind = "layout", placements = {
        { app = "Safari", screen = "DELL", pos = "left" } } })
    ok(okZ == false and reasonZ:find("move failed", 1, true) ~= nil,
        "all-moves-failed reports a move-failure reason, not a false 'no matching windows'")
    fake.failWindowFrameIds = {}
    end

    -- (c) self-gating: a placement on an ABSENT display is skipped; an all-absent
    -- layout reports no-op (so the trace explains why nothing happened)
    fake.windowFrameSets = {}
    local okD, reason = effects.dispatch({ kind = "layout",
        placements = { { app = "Safari", screen = "Thunderbolt 5K", pos = "full" } } })
    -- The reason must NAME the unplugged display + say it's not connected -- the
    -- Test button surfaces this verbatim, so "no matching windows" (= a closed app)
    -- would point the user at the wrong problem.
    ok(okD == false and type(reason) == "string"
        and reason:find("Thunderbolt 5K", 1, true) ~= nil
        and reason:find("not connected", 1, true) ~= nil,
        "an all-absent layout names the unplugged display (not a false 'no matching windows')")
    ok(#fake.windowFrameSets == 0, "no window moved when the target display is unplugged")

    -- (d) capture the CURRENT arrangement -> exact ratios on each window's display.
    -- Built-in-display windows are SKIPPED: a captured layout restores an external
    -- display's arrangement, and the built-in is always present.
    fake.windows = {
        { id = 1, appName = "Safari", title = "S", x = 100,  y = 100, w = 720,  h = 900  }, -- Built-in (skipped)
        { id = 2, appName = "Code",   title = "C", x = 1440, y = 0,   w = 2560, h = 1440 }, -- DELL, full
    }
    local snap = effects.captureLayout()
    ok(#snap == 1, "captureLayout snapshots only external-display windows (built-in skipped)")
    local code = snap[1]
    ok(code.screen == "DELL" and code.app == "Code"
        and approx(code.pos.x, 0) and approx(code.pos.y, 0)
        and approx(code.pos.w, 1) and approx(code.pos.h, 1),
        "a maximized window on the external captures as full-screen ratios on DELL")
    for _, p in ipairs(snap) do
        ok(p.screen ~= "Built-in", "no built-in-display window leaks into a capture")
    end

    -- (d2) scoped capture: with multiple monitors, naming a display grabs ONLY
    -- that display's windows (the "when <display> connects" rule case).
    fake.screenList = {
        { x = 0,    y = 0,    w = 1440, h = 900,  name = "Built-in",    index = 1, builtin = true },
        { x = 1440, y = 0,    w = 2560, h = 1440, name = "DELL",        index = 2 },
        { x = 1440, y = 1440, w = 2560, h = 1440, name = "Thunderbolt", index = 3 },
    }
    fake.windows = {
        { id = 1, appName = "Safari", title = "S", x = 100,  y = 100,  w = 720,  h = 900  }, -- Built-in
        { id = 2, appName = "Code",   title = "C", x = 1440, y = 0,     w = 2560, h = 1440 }, -- DELL
        { id = 3, appName = "Mail",   title = "M", x = 1440, y = 1440,  w = 1280, h = 1440 }, -- Thunderbolt, left half
    }
    local tb = effects.captureLayout("Thunderbolt")
    ok(#tb == 1 and tb[1].screen == "Thunderbolt" and tb[1].app == "Mail",
        "scoped capture takes ONLY the named display's windows (3-monitor setup)")
    ok(approx(tb[1].pos.x, 0) and approx(tb[1].pos.w, 0.5),
        "scoped capture keeps the window's exact ratios on its display")
    ok(#effects.captureLayout("Nonexistent") == 0,
        "scoping to an absent display captures nothing")
    ok(#effects.captureLayout() == 2,
        "unscoped capture still grabs every external display (DELL + Thunderbolt)")
    -- a captured (explicit-ratio) placement is valid + re-applies
    ok(pcall(effects.validate, { kind = "layout", placements = snap }) == true,
        "a captured layout (explicit ratios) validates")

    -- (e) the full pipeline: screenChanged event -> layout, via the rules engine
    fake.settings["hammerdeck.rules"] = nil
    rules.load({})
    fake.windows = {
        { id = 7, appName = "Safari", title = "S", x = 5, y = 5, w = 50, h = 50 },
    }
    fake.windowFrameSets = {}
    local okAdd = rules.add({
        on = { type = "event", event = "screenChanged" },
        effect = { kind = "layout", placements = {
            { app = "Safari", screen = "DELL", pos = "right" },
        } },
    })
    ok(okAdd == true, "a screenChanged -> layout rule loads (layout is context-free)")
    local d = rules.describe()
    ok(d[1].effectDesc == "Arrange 1 window", "describe() labels a single-placement layout")
    fake.systemEvent("screenChanged")
    ok(#fake.windowFrameSets == 1 and fake.windowFrameSets[1].id == 7,
        "firing screenChanged applies the layout (Safari moved)")
    -- right half of DELL: x = 1440 + 2560*0.5 = 2720, w = 1280
    ok(approx(fake.windowFrameSets[1].x, 2720) and approx(fake.windowFrameSets[1].w, 1280),
        "the window landed on the right half of the external display")

    -- (f) formOptions feeds the layout editor's pickers
    local fo = rules.formOptions()
    local sawLayout = false
    for _, e in ipairs(fo.effects) do if e.kind == "layout" then sawLayout = true end end
    ok(sawLayout, "formOptions offers the layout effect")
    ok(type(fo.layoutDisplays) == "table" and fo.layoutDisplays[1] == "Built-in"
        and fo.layoutDisplays[2] == "DELL", "formOptions lists the connected displays")
    ok(type(fo.layoutPositions) == "table" and #fo.layoutPositions == 9
        and fo.layoutPositions[1].id == "full" and type(fo.layoutPositions[1].label) == "string",
        "formOptions lists the named snap positions with labels")

    -- cleanup
    rules.load({})
    fake.settings["hammerdeck.rules"] = nil
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
    fake.windows = {}
    fake.windowFrameSets = {}
    ok(fake.liveHandles == 0, "no native handle leaked across the layout tests")
end

-- T37: displaysPresent signal (M2) -- "monitor connected/disconnected" as a named
-- state trigger. The precise form of the coarse screenChanged event: a rule on
-- `displaysPresent becomes "DELL"` fires when THAT monitor connects (membership
-- enter), `leaves` when it disconnects -- so the seed "external monitor" case is
-- expressible by name, with a symmetric disconnect for free.
fake.resetOpts()
do
    local rules   = require("platform.rules")
    local signals = require("platform.signals")

    -- docked to the laptop only
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
    fake.settings["hammerdeck.rules"] = nil
    rules.load({})

    -- (a) displaysPresent is a known signal; its value is the connected-display set
    ok(signals.exists("displaysPresent"), "displaysPresent is a registered signal")
    local sig = signals.get("displaysPresent")
    local cur = sig.read()
    ok(type(cur) == "table" and cur[1] == "Built-in", "displaysPresent reads the connected display set")
    ok(sig.match(cur, "Built-in") == true and sig.match(cur, "DELL") == false,
        "membership match: Built-in is present, DELL is not")

    -- (b) a 'becomes' rule fires when THAT monitor connects, not on unrelated changes
    local nB = #fake.notifications
    ok(rules.add({
        on = { type = "state", signal = "displaysPresent", becomes = "DELL" },
        effect = { kind = "notify", title = "Docked", text = "DELL connected" },
    }) == true, "a displaysPresent-becomes rule loads (automated trigger, context-free effect)")
    fake.systemEvent("screenChanged")   -- same set (e.g. a resolution tweak)
    ok(#fake.notifications == nB, "screenChanged with no new display does not fire the connect rule")
    fake.screenList = {
        { x = 0,    y = 0, w = 1440, h = 900,  name = "Built-in", index = 1 },
        { x = 1440, y = 0, w = 2560, h = 1440, name = "DELL",     index = 2 },
    }
    fake.systemEvent("screenChanged")
    ok(#fake.notifications == nB + 1, "DELL connects -> the rule fires (membership enter)")
    fake.systemEvent("screenChanged")
    ok(#fake.notifications == nB + 1, "a further screenChanged with DELL still present does not re-fire")

    -- (c) a 'leaves' rule fires on DISCONNECT; the 'becomes' rule does not
    rules.add({
        on = { type = "state", signal = "displaysPresent", leaves = "DELL" },
        effect = { kind = "notify", title = "Undocked", text = "DELL gone" },
    })
    local nL = #fake.notifications
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
    fake.systemEvent("screenChanged")
    ok(#fake.notifications == nL + 1, "DELL disconnects -> only the 'leaves' rule fires")

    -- (d) formOptions exposes displaysPresent + its candidate displays
    local fo = rules.formOptions()
    local sawDisplays = false
    for _, s in ipairs(fo.signals) do if s == "displaysPresent" then sawDisplays = true end end
    ok(sawDisplays, "formOptions lists displaysPresent as a signal")
    ok(type(fo.signalCandidates.displaysPresent) == "table"
        and fo.signalCandidates.displaysPresent[1] == "Built-in",
        "formOptions offers the connected displays as candidates")

    -- cleanup
    rules.load({})
    fake.settings["hammerdeck.rules"] = nil
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
    ok(fake.liveHandles == 0, "no native handle leaked across the displaysPresent tests")
end

-- T38: the new state signals (M2) -- appearance (scalar), runningApps (membership),
-- powerSource (scalar). Each re-reads on a coarse onSystemEvent and fires on the
-- becomes/leaves transition; formOptions carries each signal's UI metadata so the
-- Rules form needs no per-signal Swift code.
fake.resetOpts()
do
    local rules   = require("platform.rules")
    local signals = require("platform.signals")

    fake.settings["hammerdeck.rules"] = nil
    rules.load({})

    -- (a) appearance: a scalar "dark"/"light" signal, fires on the transition
    fake.appearance = "light"
    ok(signals.exists("appearance"), "appearance is a registered signal")
    ok(signals.get("appearance").read() == "light", "appearance reads the current mode")
    local nB = #fake.notifications
    rules.add({ on = { type = "state", signal = "appearance", becomes = "dark" },
                effect = { kind = "notify", title = "Dark" } })
    fake.systemEvent("appearanceChanged")   -- still light
    ok(#fake.notifications == nB, "appearanceChanged with no real change does not fire")
    fake.appearance = "dark"
    fake.systemEvent("appearanceChanged")
    ok(#fake.notifications == nB + 1, "appearance becomes dark -> fires")

    -- (b) runningApps: a membership set signal, "launches"/"quits". Like frontmostApp
    -- it now matches by the stable BUNDLE ID (name as a fallback); the value is a list
    -- of { name, bundleId }.
    rules.load({})
    fake.runningAppInfoList = { { name = "Finder", bundleId = "com.apple.finder" } }
    ok(signals.get("runningApps").match(
        { { name = "Finder", bundleId = "com.apple.finder" },
          { name = "Safari", bundleId = "com.apple.Safari" } }, "com.apple.Safari") == true,
        "runningApps membership matches by bundle id")
    ok(signals.get("runningApps").match(
        { { name = "Finder", bundleId = "com.apple.finder" } }, "Finder") == true,
        "runningApps membership also matches by name (fallback)")
    local nL = #fake.notifications
    rules.add({ on = { type = "state", signal = "runningApps", becomes = "Slack",
                       bundleId = "com.tinyspeck.slackmacgap" },
                effect = { kind = "notify", title = "Slack up" } })
    fake.runningAppInfoList = { { name = "Finder", bundleId = "com.apple.finder" },
                               { name = "Slack",  bundleId = "com.tinyspeck.slackmacgap" } }
    fake.systemEvent("appsChanged")
    ok(#fake.notifications == nL + 1, "Slack launches (matched by bundle id) -> the runningApps rule fires")
    fake.runningAppInfoList = { { name = "Finder", bundleId = "com.apple.finder" } }
    fake.systemEvent("appsChanged")
    ok(#fake.notifications == nL + 1, "Slack quitting does not fire a 'launches' rule")

    -- (c) powerSource: scalar "ac"/"battery"
    rules.load({})
    fake.power = "ac"
    local nP = #fake.notifications
    rules.add({ on = { type = "state", signal = "powerSource", becomes = "battery" },
                effect = { kind = "notify", title = "Unplugged" } })
    fake.power = "battery"
    fake.systemEvent("powerChanged")
    ok(#fake.notifications == nP + 1, "unplugging (powerSource becomes battery) -> fires")

    -- (d) formOptions carries signal metadata (label + transition verbs) for the form
    local fo = rules.formOptions()
    ok(type(fo.signalMeta) == "table", "formOptions includes signalMeta")
    ok(fo.signalMeta.appearance and fo.signalMeta.appearance.label == "Appearance",
        "signalMeta carries a label per signal")
    ok(fo.signalMeta.runningApps and fo.signalMeta.runningApps.enterVerb == "launches",
        "signalMeta carries the transition verbs (runningApps: launches/quits)")
    -- bundleIdMatch rides signalMeta so the host gates its installed-apps app picker on
    -- the signal's capability, not a hardcoded name: true for the app-identity signals,
    -- false (default) for an enum signal like appearance.
    ok(fo.signalMeta.frontmostApp and fo.signalMeta.frontmostApp.bundleIdMatch == true,
        "signalMeta marks frontmostApp as bundleIdMatch")
    ok(fo.signalMeta.runningApps and fo.signalMeta.runningApps.bundleIdMatch == true,
        "signalMeta marks runningApps as bundleIdMatch")
    ok(fo.signalMeta.appearance and fo.signalMeta.appearance.bundleIdMatch == false,
        "signalMeta marks an enum signal (appearance) as NOT bundleIdMatch")
    -- goneOnLeave rides signalMeta so the host can warn when a from-trigger effect
    -- binds on a leave edge whose entity is gone (runningApps quits, displaysPresent
    -- disconnects) -- but NOT frontmostApp, whose "loses focus" keeps the app alive.
    ok(fo.signalMeta.runningApps and fo.signalMeta.runningApps.goneOnLeave == true,
        "signalMeta marks runningApps goneOnLeave (a quit app is gone)")
    ok(fo.signalMeta.displaysPresent and fo.signalMeta.displaysPresent.goneOnLeave == true,
        "signalMeta marks displaysPresent goneOnLeave (a disconnected display is gone)")
    ok(fo.signalMeta.frontmostApp and not fo.signalMeta.frontmostApp.goneOnLeave,
        "signalMeta does NOT mark frontmostApp goneOnLeave (losing focus keeps it alive)")
    -- timing subtitle (the verb-popover footgun-killer) rides signalMeta too
    ok(fo.signalMeta.frontmostApp and fo.signalMeta.frontmostApp.leaveWhen == "the moment you click away",
        "signalMeta carries the per-edge timing copy (frontmostApp leaveWhen)")
    ok(type(fo.signalCandidates.powerSource) == "table"
        and fo.signalCandidates.powerSource[1] == "ac",
        "powerSource offers ac/battery as candidates")

    -- cleanup
    rules.load({})
    fake.settings["hammerdeck.rules"] = nil
    fake.appearance = "light"; fake.runningAppInfoList = {}; fake.power = "ac"
    ok(fake.liveHandles == 0, "no native handle leaked across the new-signal tests")
end

-- T39: curated atomic effects (M3) -- runShortcut (the Shortcuts escape hatch),
-- openURL, lockScreen. All context-free, so they validate + fire on automated
-- triggers and the form's Do dropdown offers them.
fake.resetOpts()
do
    local effects = require("platform.effects")
    local rules   = require("platform.rules")

    fake.settings["hammerdeck.rules"] = nil
    rules.load({})

    -- context-free + validated
    ok(effects.requiresContext({ kind = "runShortcut", name = "X" }) == false, "runShortcut is context-free")
    ok(effects.requiresContext({ kind = "openURL", url = "x" }) == false, "openURL is context-free")
    ok(effects.requiresContext({ kind = "lockScreen" }) == false, "lockScreen is context-free")
    ok(pcall(effects.validate, { kind = "runShortcut" }) == false, "runShortcut requires a name")
    ok(pcall(effects.validate, { kind = "openURL" }) == false, "openURL requires a url")
    ok(pcall(effects.validate, { kind = "lockScreen" }) == true, "lockScreen needs no params")

    -- dispatch routes to the adapter
    local nS = #fake.shortcutsRun
    effects.dispatch({ kind = "runShortcut", name = "Wind Down" })
    ok(#fake.shortcutsRun == nS + 1 and fake.shortcutsRun[#fake.shortcutsRun] == "Wind Down",
        "runShortcut dispatch runs the named Shortcut")
    local nU = #fake.openedUrls
    effects.dispatch({ kind = "openURL", url = "https://hammerdeck.app" })
    ok(#fake.openedUrls == nU + 1, "openURL dispatch opens the url")
    local nL = fake.actions.lock
    effects.dispatch({ kind = "lockScreen" })
    ok(fake.actions.lock == nL + 1, "lockScreen dispatch locks the screen")

    -- startScreensaver: a param-free context-free effect (sibling of lockScreen)
    ok(effects.requiresContext({ kind = "startScreensaver" }) == false, "startScreensaver is context-free")
    ok(pcall(effects.validate, { kind = "startScreensaver" }) == true, "startScreensaver needs no params")
    ok(effects.describe({ kind = "startScreensaver" }) == "Start the screensaver", "describe labels startScreensaver")
    local nSS = fake.actions.screensaver
    effects.dispatch({ kind = "startScreensaver" })
    ok(fake.actions.screensaver == nSS + 1, "startScreensaver dispatch starts the screensaver")

    -- speak: a context-free parameterized effect (a spoken sibling of notify)
    ok(effects.requiresContext({ kind = "speak", text = "hi" }) == false, "speak is context-free")
    ok(pcall(effects.validate, { kind = "speak", text = "hello" }) == true, "speak validates with text")
    ok(pcall(effects.validate, { kind = "speak" }) == false, "speak requires text")
    ok(pcall(effects.validate, { kind = "speak", text = "" }) == false, "speak rejects empty text")
    ok(effects.describe({ kind = "speak", text = "Standup" }) == 'Say "Standup"', "describe labels a speak effect")
    local nSp = #fake.spokenTexts
    effects.dispatch({ kind = "speak", text = "Battery low" })
    ok(#fake.spokenTexts == nSp + 1 and fake.spokenTexts[#fake.spokenTexts] == "Battery low",
        "speak dispatch says the text")

    -- emptyTrash / eject: param-free context-free system effects
    ok(effects.requiresContext({ kind = "emptyTrash" }) == false, "emptyTrash is context-free")
    ok(effects.requiresContext({ kind = "eject" }) == false, "eject is context-free")
    ok(pcall(effects.validate, { kind = "emptyTrash" }) == true, "emptyTrash needs no params")
    ok(pcall(effects.validate, { kind = "eject" }) == true, "eject needs no params")
    ok(effects.describe({ kind = "emptyTrash" }) == "Empty the Trash", "describe labels emptyTrash")
    ok(effects.describe({ kind = "eject" }) == "Eject external disks", "describe labels eject")
    local nT = fake.trashEmptied
    fake.trashReturn = 3
    local okT, noteT = effects.dispatch({ kind = "emptyTrash" })
    ok(fake.trashEmptied == nT + 1, "emptyTrash dispatch empties the trash")
    ok(okT == true and noteT == "emptied 3 items", "emptyTrash surfaces the count as a note")
    fake.trashReturn = 0   -- already empty: clean success, no note
    local okT0, noteT0 = effects.dispatch({ kind = "emptyTrash" })
    ok(okT0 == true and noteT0 == nil, "empty Trash is a clean success with no note")
    fake.trashReturn = -1  -- found items, removed none: a Full Disk Access denial
    local okTf, noteTf = effects.dispatch({ kind = "emptyTrash" })
    ok(okTf == false and noteTf:find("Full Disk Access"), "emptyTrash -1 surfaces a real failure")
    fake.trashReturn = 3   -- restore default
    local nEj = fake.ejected
    fake.ejectReturn = 1
    local okE, noteE = effects.dispatch({ kind = "eject" })
    ok(fake.ejected == nEj + 1, "eject dispatch ejects disks")
    ok(okE == true and noteE == "ejected 1 disk", "eject surfaces the count as a note")
    fake.ejectReturn = -1  -- disks present but all busy
    local okEf, noteEf = effects.dispatch({ kind = "eject" })
    ok(okEf == false and noteEf:find("busy"), "eject -1 surfaces a real failure")
    fake.ejectReturn = 1   -- restore default

    -- setAppearance / volume / mediaKey: the three system state-changers demoted
    -- from thin standalone features to grouped rules atoms. Each carries one enum
    -- param the guided form's sub-picker sets; all context-free.
    ok(effects.requiresContext({ kind = "setAppearance", mode = "dark" }) == false, "setAppearance is context-free")
    ok(pcall(effects.validate, { kind = "setAppearance", mode = "dark" }) == true, "setAppearance validates a mode")
    ok(pcall(effects.validate, { kind = "setAppearance" }) == false, "setAppearance requires a mode")
    ok(pcall(effects.validate, { kind = "setAppearance", mode = "sepia" }) == false, "setAppearance rejects a bad mode")
    ok(effects.describe({ kind = "setAppearance", mode = "dark" }) == "Switch to dark", "describe labels setAppearance dark")
    ok(effects.describe({ kind = "setAppearance", mode = "toggle" }) == "Toggle dark mode", "describe labels setAppearance toggle")
    local nA = #fake.appearanceSet
    effects.dispatch({ kind = "setAppearance", mode = "light" })
    ok(#fake.appearanceSet == nA + 1 and fake.appearanceSet[#fake.appearanceSet] == "light",
        "setAppearance dispatch sets the appearance")

    ok(effects.requiresContext({ kind = "volume", op = "up" }) == false, "volume is context-free")
    ok(pcall(effects.validate, { kind = "volume", op = "mute" }) == true, "volume validates an op")
    ok(pcall(effects.validate, { kind = "volume" }) == false, "volume requires an op")
    ok(pcall(effects.validate, { kind = "volume", op = "max" }) == false, "volume rejects a bad op")
    ok(effects.describe({ kind = "volume", op = "mute" }) == "Toggle mute", "describe labels volume mute")
    fake.volume = 50; fake.muted = false
    effects.dispatch({ kind = "volume", op = "up" })
    ok(fake.volume == 60, "volume up nudges +10")
    effects.dispatch({ kind = "volume", op = "down" })
    ok(fake.volume == 50, "volume down nudges -10")
    effects.dispatch({ kind = "volume", op = "mute" })
    ok(fake.muted == true, "volume mute toggles mute")
    fake.volumeReturn = -1   -- AppleScript error: adjustVolume returns -1
    local okVf, noteVf = effects.dispatch({ kind = "volume", op = "up" })
    ok(okVf == false and noteVf ~= nil, "volume -1 surfaces a real failure, not a lying green")
    fake.volumeReturn = nil   -- restore

    ok(effects.requiresContext({ kind = "mediaKey", key = "playpause" }) == false, "mediaKey is context-free")
    ok(pcall(effects.validate, { kind = "mediaKey", key = "next" }) == true, "mediaKey validates a key")
    ok(pcall(effects.validate, { kind = "mediaKey" }) == false, "mediaKey requires a key")
    ok(pcall(effects.validate, { kind = "mediaKey", key = "rewind" }) == false, "mediaKey rejects a bad key")
    ok(effects.describe({ kind = "mediaKey", key = "previous" }) == "Previous track", "describe labels mediaKey previous")
    fake.mediaKeys = {}
    effects.dispatch({ kind = "mediaKey", key = "playpause" })
    ok(#fake.mediaKeys == 1 and fake.mediaKeys[1] == "playpause", "mediaKey dispatch posts the transport key")

    -- end-to-end on an automated trigger: on wake -> run a Shortcut
    rules.add({ on = { type = "event", event = "wake" },
                effect = { kind = "runShortcut", name = "Morning" } })
    ok(rules.describe()[1].effectDesc == 'Run Shortcut "Morning"', "describe labels a runShortcut effect")
    local nS2 = #fake.shortcutsRun
    fake.systemEvent("wake")
    ok(#fake.shortcutsRun == nS2 + 1, "on wake -> the Shortcut runs")

    -- the Do dropdown offers all three (context-free survive automatedOnly)
    local seen = {}
    for _, e in ipairs(effects.catalog(true)) do seen[e.kind] = true end
    ok(seen.runShortcut and seen.openURL and seen.lockScreen,
        "catalog offers runShortcut + openURL + lockScreen on automated triggers")
    ok(seen.setAppearance and seen.volume and seen.mediaKey,
        "catalog offers the appearance / volume / media atoms on automated triggers")

    rules.load({}); fake.settings["hammerdeck.rules"] = nil
    ok(fake.liveHandles == 0, "no native handle leaked across the effect tests")
end

-- T39b: solidWallpaper effect -- paint a solid color on a chosen display; context-
-- free, and its `display` may be a literal/category OR drawn from the trigger
-- ("the connecting display", via the effects.TRIGGER_DISPLAY sentinel).
fake.resetOpts()
do
    local effects = require("platform.effects")
    local rules   = require("platform.rules")
    fake.settings["hammerdeck.rules"] = nil
    rules.load({})

    -- context-free + validated (needs a #RRGGBB color and a non-empty display)
    ok(effects.requiresContext({ kind = "solidWallpaper", color = "#FFFFFF", display = "all" }) == false,
        "solidWallpaper is context-free")
    ok(pcall(effects.validate, { kind = "solidWallpaper", display = "all" }) == false,
        "solidWallpaper requires a color")
    ok(pcall(effects.validate, { kind = "solidWallpaper", color = "white", display = "all" }) == false,
        "solidWallpaper rejects a non-#RRGGBB color")
    ok(pcall(effects.validate, { kind = "solidWallpaper", color = "#FFFFFF" }) == false,
        "solidWallpaper requires a display")
    ok(pcall(effects.validate, { kind = "solidWallpaper", color = "#FFFFFF", display = "all" }) == true,
        "solidWallpaper with a #RRGGBB color + display validates")

    -- dispatch routes to the adapter with a LITERAL display name
    local nW = #fake.wallpaperColors
    effects.dispatch({ kind = "solidWallpaper", color = "#FFFFFF", display = "DELL U2720Q" })
    local w = fake.wallpaperColors[#fake.wallpaperColors]
    ok(#fake.wallpaperColors == nW + 1 and w.hex == "#FFFFFF" and w.target == "DELL U2720Q",
        "solidWallpaper dispatch paints the named display")

    -- from-trigger: the sentinel resolves to context.display
    effects.dispatch({ kind = "solidWallpaper", color = "#000000", display = effects.TRIGGER_DISPLAY },
        { display = "Paperlike H D" })
    local w2 = fake.wallpaperColors[#fake.wallpaperColors]
    ok(w2.hex == "#000000" and w2.target == "Paperlike H D",
        "solidWallpaper resolves the from-trigger sentinel from the context")

    -- from-trigger with NO context display -> failure, nothing painted
    local nW2 = #fake.wallpaperColors
    local okNo = effects.dispatch({ kind = "solidWallpaper", color = "#FFFFFF", display = effects.TRIGGER_DISPLAY })
    ok(okNo == false and #fake.wallpaperColors == nW2,
        "solidWallpaper from-trigger with no connecting display does nothing")

    -- describe
    ok(effects.describe({ kind = "solidWallpaper", color = "#FFFFFF", display = "external" })
        == "Set wallpaper white on external displays", "describe labels a literal-display solidWallpaper")
    ok(effects.describe({ kind = "solidWallpaper", color = "#FFFFFF", display = effects.TRIGGER_DISPLAY })
        == "Set wallpaper white on the triggering display", "describe labels a from-trigger solidWallpaper")

    -- end-to-end: "Paperlike H D connects" -> paint THE connecting display white.
    -- triggerContext derives {display = becomes}, so the sentinel resolves to it.
    local _, sid = rules.add({
        on = { type = "state", signal = "displaysPresent", becomes = "Paperlike H D" },
        effect = { kind = "solidWallpaper", color = "#FFFFFF", display = effects.TRIGGER_DISPLAY } })
    local nW3 = #fake.wallpaperColors
    ok(rules.fire(sid) == true, "a solidWallpaper rule fires (Test)")
    local w3 = fake.wallpaperColors[#fake.wallpaperColors]
    ok(#fake.wallpaperColors == nW3 + 1 and w3.hex == "#FFFFFF" and w3.target == "Paperlike H D",
        "the connecting display name flows from the rule's condition into the effect")

    -- the Do dropdown offers it on automated triggers
    local seen = {}
    for _, e in ipairs(effects.catalog(true)) do seen[e.kind] = true end
    ok(seen.solidWallpaper, "catalog offers solidWallpaper on automated triggers")

    rules.load({}); fake.settings["hammerdeck.rules"] = nil
    ok(fake.liveHandles == 0, "no native handle leaked across the solidWallpaper tests")
end

-- T39b2: setWallpaperImage effect -- the sibling of solidWallpaper that paints a
-- photo (adapter.setWallpaper) instead of a flat color; same display param model
-- (literal / category / from-trigger), context-free.
fake.resetOpts()
do
    local effects = require("platform.effects")
    fake.settings["hammerdeck.rules"] = nil

    ok(effects.requiresContext({ kind = "setWallpaperImage", image = "/x.jpg", display = "all" }) == false,
        "setWallpaperImage is context-free")
    ok(pcall(effects.validate, { kind = "setWallpaperImage", display = "all" }) == false,
        "setWallpaperImage requires an image path")
    ok(pcall(effects.validate, { kind = "setWallpaperImage", image = "/x.jpg" }) == false,
        "setWallpaperImage requires a display")
    ok(pcall(effects.validate, { kind = "setWallpaperImage", image = "/x.jpg", display = "all" }) == true,
        "setWallpaperImage with an image + display validates")

    -- dispatch routes to adapter.setWallpaper(path, target)
    local nW = #fake.wallpapers
    effects.dispatch({ kind = "setWallpaperImage", image = "/Users/me/Pictures/sunset.jpg", display = "DELL U2720Q" })
    ok(#fake.wallpapers == nW + 1
        and fake.wallpapers[#fake.wallpapers] == "/Users/me/Pictures/sunset.jpg"
        and fake.wallpaperModes[#fake.wallpaperModes] == "DELL U2720Q",
        "setWallpaperImage dispatch sets the photo on the named display")

    -- from-trigger sentinel resolves from context.display; missing context -> fail
    effects.dispatch({ kind = "setWallpaperImage", image = "/p.jpg", display = effects.TRIGGER_DISPLAY },
        { display = "Paperlike H D" })
    ok(fake.wallpaperModes[#fake.wallpaperModes] == "Paperlike H D",
        "setWallpaperImage resolves the from-trigger display")
    local nW2 = #fake.wallpapers
    ok(effects.dispatch({ kind = "setWallpaperImage", image = "/p.jpg", display = effects.TRIGGER_DISPLAY }) == false
        and #fake.wallpapers == nW2,
        "setWallpaperImage from-trigger with no connecting display does nothing")

    -- describe shows the file NAME, not the full path
    ok(effects.describe({ kind = "setWallpaperImage", image = "/Users/me/Pictures/sunset.jpg", display = "external" })
        == "Set wallpaper sunset.jpg on external displays", "describe labels setWallpaperImage by basename")
    ok(effects.describe({ kind = "setWallpaperImage", image = "/a/b.png", display = effects.TRIGGER_DISPLAY })
        == "Set wallpaper b.png on the triggering display", "describe: from-trigger setWallpaperImage")

    local seen = {}
    for _, e in ipairs(effects.catalog(true)) do seen[e.kind] = true end
    ok(seen.setWallpaperImage, "catalog offers setWallpaperImage on automated triggers")
end

-- T39b3: moveAppToDisplay effect -- relocate an app's window to another display
-- KEEPING its size (vs layout, which resizes). Reuses listWindows/screenFrames/
-- setWindowFrame; context-free; app/display may be from-trigger.
fake.resetOpts()
do
    local effects = require("platform.effects")
    fake.settings["hammerdeck.rules"] = nil
    fake.screenList = {
        { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1, builtin = true },
        { x = 1440, y = 0, w = 2560, h = 1440, name = "DELL U2720Q", index = 2 },
    }
    fake.windows = { { id = 7, appName = "Slack", x = 100, y = 120, w = 400, h = 300, title = "Slack" } }
    fake.windowFrameSets = {}

    ok(effects.requiresContext({ kind = "moveAppToDisplay", app = "Slack", display = "DELL U2720Q" }) == false,
        "moveAppToDisplay is context-free")
    ok(pcall(effects.validate, { kind = "moveAppToDisplay", app = "Slack" }) == false,
        "moveAppToDisplay requires a display")
    ok(pcall(effects.validate, { kind = "moveAppToDisplay", display = "DELL U2720Q" }) == false,
        "moveAppToDisplay requires an app")
    ok(pcall(effects.validate, { kind = "moveAppToDisplay", app = "Slack", display = "DELL U2720Q" }) == true,
        "moveAppToDisplay with app + display validates")

    -- dispatch keeps the SIZE (400x300) and preserves the within-screen offset:
    -- from Built-in (0,0) offset (100,120) -> DELL (1440,0) => (1540,120).
    ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Slack", display = "DELL U2720Q" }) == true,
        "moveAppToDisplay moves a matching window")
    local s = fake.windowFrameSets[#fake.windowFrameSets]
    ok(s and s.id == 7 and s.x == 1540 and s.y == 120 and s.w == 400 and s.h == 300,
        "moveAppToDisplay relocates to the display keeping the window's size + offset")

    -- a disconnected/typo'd display -> failure, no move
    fake.windowFrameSets = {}
    ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Slack", display = "Ghost" }) == false
        and #fake.windowFrameSets == 0, "moveAppToDisplay fails when the display isn't connected")

    -- no matching window -> failure
    ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Nope", display = "DELL U2720Q" }) == false,
        "moveAppToDisplay fails when no window matches the app")

    -- from-trigger: app + display resolve from context
    fake.windowFrameSets = {}
    effects.dispatch({ kind = "moveAppToDisplay", app = effects.TRIGGER_APP, display = effects.TRIGGER_DISPLAY },
        { app = "Slack", display = "DELL U2720Q" })
    ok(fake.windowFrameSets[#fake.windowFrameSets] and fake.windowFrameSets[#fake.windowFrameSets].x == 1540,
        "moveAppToDisplay resolves from-trigger app + display")

    ok(effects.describe({ kind = "moveAppToDisplay", app = "Slack", display = "DELL U2720Q" })
        == "Move Slack to DELL U2720Q", "describe labels moveAppToDisplay")

    -- restore the single-screen default so a later screen-reading test isn't
    -- polluted by this block's 2-screen config (matches the layout block's teardown)
    fake.windows = {}; fake.windowFrameSets = {}
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1, builtin = true } }
end

-- T39b4: app-target effects match by BUNDLE ID when the rule carries one (the
-- stable key, set when the user picks from the installed-apps list) -- falling back
-- to the display name for legacy rules + the from-trigger path. Proves (a) the
-- minimize/hide/quit trio pass the bundle id to the adapter, and (b) moveAppToDisplay
-- matches a window by bundleID even when its localized appName differs.
fake.resetOpts()
do
    local effects = require("platform.effects")
    fake.settings["hammerdeck.rules"] = nil

    -- minimize: with appBundleId set, the adapter is called with the BUNDLE ID.
    local nM = #fake.minimized
    effects.dispatch({ kind = "minimizeApp", app = "Slack", appBundleId = "com.tinyspeck.slackmacgap" })
    ok(#fake.minimized == nM + 1 and fake.minimized[#fake.minimized] == "com.tinyspeck.slackmacgap",
        "minimizeApp prefers the bundle id when the rule has one")

    -- no appBundleId -> the display name (legacy / from-trigger fallback).
    effects.dispatch({ kind = "minimizeApp", app = "Slack" })
    ok(fake.minimized[#fake.minimized] == "Slack",
        "minimizeApp falls back to the name with no bundle id")

    -- an empty-string appBundleId is treated as absent (name fallback), not "".
    effects.dispatch({ kind = "quitApp", app = "Slack", appBundleId = "" })
    ok(fake.quit[#fake.quit] == "Slack", "an empty appBundleId falls back to the name")

    -- moveAppToDisplay: match by bundleID even when the window's appName differs from
    -- the rule's stored display name (locale/rename drift -- exactly what bundle-id
    -- identity fixes).
    fake.screenList = {
        { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1, builtin = true },
        { x = 1440, y = 0, w = 2560, h = 1440, name = "DELL U2720Q", index = 2 },
    }
    fake.windows = { { id = 9, appName = "Slack (renamed)", bundleID = "com.tinyspeck.slackmacgap",
                       x = 100, y = 120, w = 400, h = 300, title = "Slack" } }
    fake.windowFrameSets = {}
    ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Slack",
            appBundleId = "com.tinyspeck.slackmacgap", display = "DELL U2720Q" }) == true,
        "moveAppToDisplay matches a window by bundle id despite a different appName")
    local s = fake.windowFrameSets[#fake.windowFrameSets]
    ok(s and s.id == 9 and s.x == 1540, "the bundle-id-matched window is the one moved")

    -- neither name nor bundle id matches -> no move (bundleID isn't a wildcard).
    fake.windowFrameSets = {}
    ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Nope",
            appBundleId = "com.example.nope", display = "DELL U2720Q" }) == false
        and #fake.windowFrameSets == 0,
        "moveAppToDisplay does not move when neither name nor bundle id matches")

    -- strict: with a bundle id, a DIFFERENT app that merely shares the display name
    -- is NOT moved -- bundle id is authoritative, no name over-match.
    fake.windows = { { id = 5, appName = "Slack", bundleID = "com.other.slackclone",
                       x = 10, y = 10, w = 200, h = 200, title = "x" } }
    fake.windowFrameSets = {}
    ok(effects.dispatch({ kind = "moveAppToDisplay", app = "Slack",
            appBundleId = "com.tinyspeck.slackmacgap", display = "DELL U2720Q" }) == false
        and #fake.windowFrameSets == 0,
        "moveAppToDisplay with a bundle id ignores a same-named app of a different bundle")

    fake.windows = {}; fake.windowFrameSets = {}
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1, builtin = true } }
end

-- T39b5: launchApp effect (Open an app) -- the positive counterpart to quit. Unlike
-- minimize/hide/quit (which act on a RUNNING app by name or id), launch needs the
-- BUNDLE ID (the only launchable identifier), so validate requires appBundleId; `app`
-- is just the readable name for the sentence/log. Context-free, so it can fire on an
-- automated trigger ("open Slack at 9am").
fake.resetOpts()
do
    local effects = require("platform.effects")
    fake.settings["hammerdeck.rules"] = nil

    ok(effects.requiresContext({ kind = "launchApp", app = "Slack", appBundleId = "com.tinyspeck.slackmacgap" }) == false,
        "launchApp is context-free (fires on an automated trigger)")
    -- validate needs BOTH the bundle id (launch key) and a name (for the sentence).
    ok(pcall(effects.validate, { kind = "launchApp", app = "Slack" }) == false,
        "launchApp requires a bundle id, not just a name")
    ok(pcall(effects.validate, { kind = "launchApp", appBundleId = "com.tinyspeck.slackmacgap" }) == false,
        "launchApp requires an app name for the sentence")
    ok(pcall(effects.validate, { kind = "launchApp", app = "Slack", appBundleId = "com.tinyspeck.slackmacgap" }) == true,
        "launchApp with a name + bundle id validates")
    -- no @trigger:app form (launch targets a specific installed app) -- a hand-authored
    -- one is rejected, not silently launched while the sentence reads the raw sentinel.
    ok(pcall(effects.validate, { kind = "launchApp", app = effects.TRIGGER_APP, appBundleId = "x" }) == false,
        "launchApp rejects the @trigger:app sentinel")

    -- dispatch launches by the BUNDLE ID (not the name).
    local nL = #fake.launchedApps
    ok(effects.dispatch({ kind = "launchApp", app = "Slack", appBundleId = "com.tinyspeck.slackmacgap" }) == true,
        "launchApp dispatch launches the app")
    ok(#fake.launchedApps == nL + 1 and fake.launchedApps[#fake.launchedApps] == "com.tinyspeck.slackmacgap",
        "launchApp passes the bundle id to launchOrFocusApp")

    -- a bundle id no installed app carries -> a real failure (not a lying green fire).
    fake.uninstalledApps = { ["com.example.ghost"] = true }
    ok(effects.dispatch({ kind = "launchApp", app = "Ghost", appBundleId = "com.example.ghost" }) == false,
        "launchApp fails when no installed app carries the bundle id")
    fake.uninstalledApps = nil

    -- describe reads "Open <app>" (the readable name, never the raw bundle id).
    ok(effects.describe({ kind = "launchApp", app = "Slack", appBundleId = "com.tinyspeck.slackmacgap" })
        == "Open Slack", "describe labels launchApp by name")

    -- it appears in the Do dropdown catalog (context-free -> survives automatedOnly).
    local found = false
    for _, e in ipairs(effects.catalog(true)) do if e.kind == "launchApp" then found = true end end
    ok(found, "launchApp is offered in the effects catalog for automated triggers")
end

-- T39c: minimizeApp effect -- minimize a named app's window; context-free, and its
-- `app` may be drawn from the trigger ("the app from the trigger"). The SECOND
-- context-bound effect, and the first that binds on the `leaves` edge (an app
-- losing focus) -- proving from-trigger isn't display/becomes-only.
fake.resetOpts()
do
    local effects = require("platform.effects")
    local rules   = require("platform.rules")
    fake.settings["hammerdeck.rules"] = nil
    rules.load({})

    -- context-free + validated (needs a non-empty app)
    ok(effects.requiresContext({ kind = "minimizeApp", app = "Slack" }) == false,
        "minimizeApp is context-free")
    ok(pcall(effects.validate, { kind = "minimizeApp" }) == false,
        "minimizeApp requires an app")
    ok(pcall(effects.validate, { kind = "minimizeApp", app = "Slack" }) == true,
        "minimizeApp with an app validates")

    -- dispatch routes to the adapter with a LITERAL app name
    local nM = #fake.minimized
    effects.dispatch({ kind = "minimizeApp", app = "Slack" })
    ok(#fake.minimized == nM + 1 and fake.minimized[#fake.minimized] == "Slack",
        "minimizeApp dispatch minimizes the named app")

    -- from-trigger: the sentinel resolves to context.app
    effects.dispatch({ kind = "minimizeApp", app = effects.TRIGGER_APP }, { app = "Notes" })
    ok(fake.minimized[#fake.minimized] == "Notes",
        "minimizeApp resolves the from-trigger sentinel from the context")

    -- from-trigger with NO context app -> failure, nothing minimized
    local nM2 = #fake.minimized
    local okNo = effects.dispatch({ kind = "minimizeApp", app = effects.TRIGGER_APP })
    ok(okNo == false and #fake.minimized == nM2,
        "minimizeApp from-trigger with no app does nothing")

    -- describe
    ok(effects.describe({ kind = "minimizeApp", app = "Slack" }) == "Minimize Slack",
        "describe labels a literal-app minimizeApp")
    ok(effects.describe({ kind = "minimizeApp", app = effects.TRIGGER_APP }) == "Minimize the triggering app",
        "describe labels a from-trigger minimizeApp")

    -- end-to-end on the LEAVES edge: "frontmost app leaves Slack" -> minimize Slack.
    -- triggerContext yields {app = leaves}, proving from-trigger works on `leaves`,
    -- not just `becomes` (the generalization the focus-loss case forced).
    local _, mid = rules.add({
        on = { type = "state", signal = "frontmostApp", leaves = "Slack" },
        effect = { kind = "minimizeApp", app = effects.TRIGGER_APP } })
    local nM3 = #fake.minimized
    ok(rules.fire(mid) == true, "a minimizeApp rule fires (Test)")
    ok(#fake.minimized == nM3 + 1 and fake.minimized[#fake.minimized] == "Slack",
        "the app that lost focus flows from the rule's leaves condition into the effect")

    -- usesTriggerContext + describe.contextBound -- the host hides "Test" for a
    -- reactive (from-trigger) rule, since a manual fire has no live trigger context.
    ok(effects.usesTriggerContext({ kind = "minimizeApp", app = effects.TRIGGER_APP }) == true,
        "usesTriggerContext detects a from-trigger param")
    ok(effects.usesTriggerContext({ kind = "minimizeApp", app = "Slack" }) == false,
        "usesTriggerContext is false for a literal param")
    ok(effects.usesTriggerContext({ kind = "chain", effects = {
        { kind = "lockScreen" },
        { kind = "solidWallpaper", color = "#FFFFFF", display = effects.TRIGGER_DISPLAY } } }) == true,
        "usesTriggerContext recurses into chain steps")
    do
        local row
        for _, r in ipairs(rules.describe()) do if r.id == mid then row = r end end
        ok(row and row.contextBound == true, "describe flags a from-trigger rule as contextBound")
    end

    -- hideApp / quitApp: same {app} shape + context-binding, different verb.
    ok(pcall(effects.validate, { kind = "hideApp" }) == false, "hideApp requires an app")
    ok(pcall(effects.validate, { kind = "quitApp", app = "Mail" }) == true, "quitApp with an app validates")
    ok(effects.requiresContext({ kind = "hideApp", app = "Mail" }) == false, "hideApp is context-free")
    local nH = #fake.hidden
    effects.dispatch({ kind = "hideApp", app = "Mail" })
    ok(#fake.hidden == nH + 1 and fake.hidden[#fake.hidden] == "Mail", "hideApp dispatch hides the app")
    local nQ = #fake.quit
    effects.dispatch({ kind = "quitApp", app = effects.TRIGGER_APP }, { app = "Notes" })
    ok(#fake.quit == nQ + 1 and fake.quit[#fake.quit] == "Notes", "quitApp resolves @trigger:app from context")
    ok(effects.describe({ kind = "hideApp", app = "Mail" }) == "Hide Mail", "describe labels hideApp")
    ok(effects.describe({ kind = "quitApp", app = effects.TRIGGER_APP }) == "Quit the triggering app",
        "describe labels a from-trigger quitApp")

    -- the Do dropdown offers them on automated triggers
    local seen = {}
    for _, e in ipairs(effects.catalog(true)) do seen[e.kind] = true end
    ok(seen.minimizeApp and seen.hideApp and seen.quitApp,
        "catalog offers minimizeApp + hideApp + quitApp on automated triggers")

    rules.load({}); fake.settings["hammerdeck.rules"] = nil
    ok(fake.liveHandles == 0, "no native handle leaked across the app-target effect tests")
end

-- T40: chain effect (M3) -- run several sub-effects IN ORDER; context-free iff every
-- step is; partial-success aggregation names the failed steps --------------------
fake.resetOpts()
do
    local effects = require("platform.effects")
    local rules   = require("platform.rules")
    fake.settings["hammerdeck.rules"] = nil
    rules.load({})

    -- validate: needs >= 1 step, each a valid effect, no nesting
    ok(pcall(effects.validate, { kind = "chain", effects = {} }) == false,
        "a chain needs at least one step")
    ok(pcall(effects.validate, { kind = "chain", effects = {
        { kind = "chain", effects = { { kind = "lockScreen" } } } } }) == false,
        "a chain step cannot itself be a chain (no nesting)")
    ok(pcall(effects.validate, { kind = "chain", effects = { { kind = "notify" } } }) == false,
        "a chain rejects an invalid step (notify needs a title)")
    ok(pcall(effects.validate, { kind = "chain", effects = {
        { kind = "notify", title = "hi" }, { kind = "runShortcut", name = "DND" } } }) == true,
        "a chain of valid steps validates")

    -- context policy: context-free iff EVERY step is
    ok(effects.requiresContext({ kind = "chain", effects = {
        { kind = "notify", title = "hi" }, { kind = "lockScreen" } } }) == false,
        "a chain of context-free steps is context-free")
    ok(effects.requiresContext({ kind = "chain", effects = {
        { kind = "notify", title = "hi" }, { kind = "command", feature = "ghost", action = "x" } } }) == true,
        "a chain with a context-requiring step requires context")

    -- describe lists the steps (the compact list-row / fire-log form)
    ok(effects.describe({ kind = "chain", effects = {
        { kind = "notify", title = "hi" }, { kind = "runShortcut", name = "DND" } } })
        == '2 steps: Notify "hi" -> Run Shortcut "DND"', "describe lists the chain steps")
    -- pronoun mode renders the chain as one flowing sentence (the read-back),
    -- lowercasing each step after the first and joining with ", then ".
    ok(effects.describe({ kind = "chain", effects = {
        { kind = "minimizeApp", app = effects.TRIGGER_APP }, { kind = "notify", title = "Done" } } },
        { pronoun = true })
        == 'Minimize it, then notify "Done"', "describe chain pronoun mode joins with 'then'")

    -- dispatch runs every step IN ORDER
    local nN, nS = #fake.notifications, #fake.shortcutsRun
    ok(effects.dispatch({ kind = "chain", effects = {
        { kind = "notify", title = "one" }, { kind = "runShortcut", name = "two" } } }) == true
        and #fake.notifications == nN + 1 and #fake.shortcutsRun == nS + 1,
        "a chain dispatches every step")

    -- partial: one step fails (layout with no present display) -> ran K/N note
    fake.screenList = { { x = 0, y = 0, w = 1440, h = 900, name = "Built-in", index = 1 } }
    fake.windows = {}
    local okP, noteP = effects.dispatch({ kind = "chain", effects = {
        { kind = "notify", title = "ok" },
        { kind = "layout", placements = { { app = "X", screen = "Ghost", pos = "full" } } } } })
    ok(okP == true and type(noteP) == "string" and noteP:find("1/2", 1, true) ~= nil
        and noteP:find("step 2", 1, true) ~= nil,
        "a partial chain returns a note naming the failed step (ran 1/2)")

    -- every step fails -> (false, reason)
    local okF, reasonF = effects.dispatch({ kind = "chain", effects = {
        { kind = "layout", placements = { { app = "X", screen = "Ghost", pos = "full" } } } } })
    ok(okF == false and reasonF:find("every step failed", 1, true) ~= nil,
        "an all-failed chain reports failure")

    -- end-to-end: on wake -> notify + runShortcut (all context-free, so allowed)
    local nS3 = #fake.shortcutsRun
    ok(rules.add({ on = { type = "event", event = "wake" },
        effect = { kind = "chain", effects = {
            { kind = "notify", title = "morning" }, { kind = "runShortcut", name = "Coffee" } } } }) == true,
        "a chain rule on an automated trigger loads (all steps context-free)")
    fake.systemEvent("wake")
    ok(#fake.shortcutsRun == nS3 + 1, "on wake -> the chain runs its Shortcut step")

    -- context policy backstop: a chain with a context step is REFUSED on an automated trigger
    ok(select(1, rules.add({ on = { type = "event", event = "wake" },
        effect = { kind = "chain", effects = {
            { kind = "command", feature = "ghost", action = "x" } } } })) == false,
        "an automated trigger refuses a chain with a context-requiring step")

    -- the Do dropdown offers chain
    local seen = {}
    for _, e in ipairs(effects.catalog(true)) do seen[e.kind] = true end
    ok(seen.chain, "catalog offers the chain effect")

    rules.load({}); fake.settings["hammerdeck.rules"] = nil
    fake.windows = {}
    ok(fake.liveHandles == 0, "no native handle leaked across the chain tests")
end

-- T40b: rules.sentence -- the plain-language read-back shown live above the rule
-- form (the redesign's comprehension win: a rule reads as one English line, and a
-- from-trigger param reads as "it"). Pure formatting over signals.meta + describe.
fake.resetOpts()
do
    local effects = require("platform.effects")
    local rules   = require("platform.rules")

    -- ENTITY signal, leaves edge, app drawn from the trigger -> "it"
    ok(rules.sentence({
        on = { type = "state", signal = "frontmostApp", leaves = "Slack" },
        effect = { kind = "minimizeApp", app = effects.TRIGGER_APP } })
        == "When Slack loses focus, minimize it.",
        "sentence: app loses focus -> minimize it")
    -- ENTITY signal, becomes edge, display from the trigger
    ok(rules.sentence({
        on = { type = "state", signal = "displaysPresent", becomes = "DELL U2720Q" },
        effect = { kind = "solidWallpaper", color = "#FFFFFF", display = effects.TRIGGER_DISPLAY } })
        == "When DELL U2720Q connects, set wallpaper white on it.",
        "sentence: display connects -> wallpaper on it")
    -- PROPERTY signal (no `provides`) reads "the <name> <verb> <value>"
    ok(rules.sentence({
        on = { type = "state", signal = "powerSource", becomes = "battery" },
        effect = { kind = "solidWallpaper", color = "#000000", display = "all" } })
        == "When the power source becomes battery, set wallpaper black on all displays.",
        "sentence: property signal reads 'the X becomes Y'")
    -- PROPERTY signal, LEAVE edge -> "is no longer X" (a bare "leaves battery" is
    -- ungrammatical for a subject-less property; see signals.lua leaveVerb).
    ok(rules.sentence({
        on = { type = "state", signal = "powerSource", leaves = "battery" },
        effect = { kind = "lockScreen" } })
        == "When the power source is no longer battery, lock the screen.",
        "sentence: property leave edge reads 'is no longer'")
    -- a CHAIN effect reads as one flowing line ("..., then ..."), not "N steps: ..."
    ok(rules.sentence({
        on = { type = "state", signal = "frontmostApp", leaves = "Slack" },
        effect = { kind = "chain", effects = {
            { kind = "minimizeApp", app = effects.TRIGGER_APP }, { kind = "notify", title = "Done" } } } })
        == 'When Slack loses focus, minimize it, then notify "Done".',
        "sentence: a chain reads as one flowing line")
    -- event
    ok(rules.sentence({
        on = { type = "event", event = "wake" }, effect = { kind = "notify", title = "Hi" } })
        == 'When the Mac wakes, notify "Hi".', "sentence: event clause")
    -- schedule LEADS the line (no "When") -- both the daily-at and every-N forms
    ok(rules.sentence({
        on = { type = "schedule", at = "18:00" }, effect = { kind = "lockScreen" } })
        == "Every day at 18:00, lock the screen.", "sentence: schedule (at) leads the line")
    ok(rules.sentence({
        on = { type = "schedule", everyMin = 25 }, effect = { kind = "lockScreen" } })
        == "Every 25 minutes, lock the screen.", "sentence: schedule (everyMin) -- the %d branch")
    -- incomplete (no value) -> empty, so the host shows its placeholder
    ok(rules.sentence({
        on = { type = "state", signal = "frontmostApp" }, effect = { kind = "lockScreen" } }) == "",
        "sentence: a missing trigger value -> empty")
    -- the JSON wrapper the host calls
    ok(rules.sentenceJSON('{"on":{"type":"event","event":"sleep"},"effect":{"kind":"lockScreen"}}')
        == "When the Mac sleeps, lock the screen.", "sentenceJSON decodes + composes")
    ok(rules.sentenceJSON("not json") == "", "sentenceJSON: bad input -> empty")

    -- pronoun mode is OPT-IN: the default describe (list row / log) is unchanged.
    ok(effects.describe({ kind = "minimizeApp", app = effects.TRIGGER_APP }) == "Minimize the triggering app",
        "describe default keeps 'the triggering app'")
    ok(effects.describe({ kind = "minimizeApp", app = effects.TRIGGER_APP }, { pronoun = true }) == "Minimize it",
        "describe pronoun mode renders the from-trigger app as 'it'")
end

-- T41: notify delivery channel (M3) -- a notify can target the macOS Notification
-- Center ("system") or the in-app banner ("app", default), with a toast fallback --
fake.resetOpts()
do
    local effects = require("platform.effects")

    -- validate: channel is optional, "system" | "app"
    ok(pcall(effects.validate, { kind = "notify", title = "hi", channel = "system" }) == true,
        "notify accepts channel = system")
    ok(pcall(effects.validate, { kind = "notify", title = "hi", channel = "app" }) == true,
        "notify accepts channel = app")
    ok(pcall(effects.validate, { kind = "notify", title = "hi" }) == true,
        "notify channel is optional")
    ok(pcall(effects.validate, { kind = "notify", title = "hi", channel = "pigeon" }) == false,
        "notify rejects an unknown channel")

    -- a system notify is still context-free (safe on automated triggers)
    ok(effects.requiresContext({ kind = "notify", title = "hi", channel = "system" }) == false,
        "a system notify is still context-free")

    -- channel = system -> Notification Center, NOT the in-app banner
    fake.systemNotifyDelivers = true
    local nSys, nApp = #fake.systemNotifications, #fake.notifications
    ok(effects.dispatch({ kind = "notify", title = "sys", channel = "system" }) == true
        and #fake.systemNotifications == nSys + 1 and #fake.notifications == nApp,
        "channel=system delivers to the Notification Center, not the in-app banner")

    -- channel = app (and absent) -> the in-app banner, NOT the system center
    nSys, nApp = #fake.systemNotifications, #fake.notifications
    effects.dispatch({ kind = "notify", title = "app", channel = "app" })
    effects.dispatch({ kind = "notify", title = "default" })
    ok(#fake.notifications == nApp + 2 and #fake.systemNotifications == nSys,
        "channel=app (and absent) shows the in-app banner")

    -- system unavailable (no app bundle, e.g. dev `swift run`) -> falls back + a note
    fake.systemNotifyDelivers = false
    nApp = #fake.notifications
    local okF, noteF = effects.dispatch({ kind = "notify", title = "fb", channel = "system" })
    ok(okF == true and #fake.notifications == nApp + 1
        and type(noteF) == "string" and noteF:find("in-app", 1, true) ~= nil,
        "an undeliverable system notify falls back to the in-app banner with a note")
    fake.systemNotifyDelivers = true
end

-- Phase 1 (RUN_LUA_SPLIT_SPEC): run the migrated hermetic cases, each in a fresh
-- world, AFTER the (shrinking) legacy monolith above. Each case owns its fixtures;
-- the freshWorld() before it and the handle tripwire after keep it isolated -- a
-- STRONGER guarantee than the monolith's scattered positional liveHandles checks,
-- since every case is checked. `arg` may name one case (narrowing the cases loop;
-- the monolith above still runs this phase) or pass --shuffle (order self-check).
for _, case in ipairs(harness.discover("test/cases", arg)) do
    harness.freshWorld()
    case.run(t)
    ok(fake.liveHandles == 0 and registry.liveHandleCount() == 0,
        case.id .. ": leaked no native handles")
end

harness.report()
