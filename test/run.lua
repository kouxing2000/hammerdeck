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

-- T34 (rules engine M0: bind ANY trigger to ANY effect across features -- event +
--   manual-hotkey rules, the automatable context policy, malformed-rule quarantine,
--   a disabled target firing as a no-op, loadFromSettings) migrated to
--   test/cases/_integration/rules/rules_engine_m0.lua (RUN_LUA_SPLIT_SPEC Phase 3).

-- T35..T41 -- the rules-engine cluster (M1 state-signals/notify/mutation, M2 signals +
-- window-layout, M3 curated effects) migrated to test/cases/_integration/rules/rules_*.lua
-- (RUN_LUA_SPLIT_SPEC Phase 3). One hermetic case per section:
--   T35      -> rules/rules_state_signals.lua        (M1 state triggers, notify effect, mutation API)
--   T35a-P10 -> rules/rules_effect_failure_alert.lua  (a persistently failing effect alerts once)
--   T35b     -> rules/rules_frontmost_bundleid.lua    (frontmostApp matches by bundle id)
--   T35p     -> rules/rules_parking.lua               (a rule whose target is absent this boot is parked)
--   T35f     -> rules/rules_fire_status.lua           (describe() reports each rule's last-fire status)
--   T36      -> rules/rules_window_layout.lua         (M2 window-layout effect on named displays)
--   T37      -> rules/rules_displays_present.lua       (M2 displaysPresent signal)
--   T38      -> rules/rules_signals_m2.lua            (M2 appearance/runningApps/... state signals)
--   T39      -> rules/rules_atomic_effects.lua        (M3 curated atomic effects: runShortcut, ...)
--   T39b     -> rules/rules_solid_wallpaper.lua       (solidWallpaper effect)
--   T39b2    -> rules/rules_set_wallpaper_image.lua    (setWallpaperImage effect)
--   T39b3    -> rules/rules_move_app_to_display.lua    (moveAppToDisplay effect)
--   T39b4    -> rules/rules_app_target_bundleid.lua    (app-target effects match by bundle id)
--   T39b5    -> rules/rules_launch_app.lua            (launchApp effect)
--   T39c     -> rules/rules_minimize_app.lua          (minimizeApp effect)
--   T40      -> rules/rules_chain_effect.lua          (chain effect: sub-effects in order)
--   T40b     -> rules/rules_sentence.lua              (rules.sentence plain-language read-back)
--   T41      -> rules/rules_notify_delivery.lua        (notify delivery channel + in-app fallback)

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
