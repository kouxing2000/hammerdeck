-- test/cases/_integration/rules/rules_window_layout.lua -- window-layout effect (M2) -- place windows on named displays, self-gating,
-- capture-current-arrangement, and the screenChanged -> layout pipeline ---------
-- The seed automation: an external monitor connects (screenChanged) and assigned
-- apps snap to assigned rects on assigned displays. A layout placement is
-- SELF-GATING -- it targets a display by name, so it no-ops when that monitor is
-- unplugged, which is why a coarse screenChanged trigger is enough.
--
-- Migrated from run.lua T36 (RUN_LUA_SPLIT_SPEC Phase 3, the rules-engine cluster).
-- Integration: platform subsystem, driven by throwaway features/effects. Hermetic --
-- freshWorld() runs registry.reset() + rules.load({}) before the case, so the catalog
-- and the rules singleton both start empty.

return {
    id = "rules_window_layout",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake
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
    end,
}
