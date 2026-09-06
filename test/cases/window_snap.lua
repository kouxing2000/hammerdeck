-- test/cases/window_snap.lua -- window_snap: half/toggle/maximize snaps, fullscreen
-- retry, cross-screen throw with pointer carry, whole-display swap (2 = immediate,
-- 3 = spatial picker, 1 = alert, no-AX onboarding), plus its PLACEMENT PRESETS (the
-- dynamicActions hook that turns each saved preset into a rebindable preset_<uuid>).
--
-- Migrated from run.lua T24 + T24p (RUN_LUA_SPLIT_SPEC Phase 2). Both are window_snap
-- behavior in its own namespace; the case registers its own copy. freshWorld() +
-- handle tripwire keep it isolated.

return {
    id = "window_snap",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry, AC, lastFrame = t.ok, t.fake, t.registry, t.AC, t.lastFrame

        registry.register(require("features.window_snap"))
        registry.setEnabled("window_snap", true)

        fake.screenList = {
            { x = 0, y = 0, w = 1000, h = 800 },        -- primary
            { x = 1000, y = 0, w = 2000, h = 1200 },    -- bigger secondary
        }
        -- halves snap against the window's own screen
        fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
        fake.pressHotkey("left", AC)
        local lf = lastFrame()
        ok(lf.x == 0 and lf.y == 0 and lf.w == 500 and lf.h == 800, "left half snaps")
        fake.pressHotkey("right", AC)
        lf = lastFrame()
        ok(lf.x == 500 and lf.w == 500 and lf.h == 800, "right half snaps")
        fake.pressHotkey("down", AC)
        lf = lastFrame()
        ok(lf.y == 400 and lf.w == 1000 and lf.h == 400, "bottom half snaps")

        -- toggle: full-width window -> centered 75%; then -> maximize
        fake.pressHotkey("return", AC)             -- bottom half is full-width
        lf = lastFrame()
        ok(lf.x == 125 and lf.y == 100 and lf.w == 750 and lf.h == 600,
            "full-dimension window toggles to centered 75%")
        fake.pressHotkey("return", AC)
        lf = lastFrame()
        ok(lf.x == 0 and lf.y == 0 and lf.w == 1000 and lf.h == 800,
            "75% window toggles to maximized")

        -- fullscreen: exits, then retries after the settle timer
        fake.focusedWindow = { x = 0, y = 0, w = 1000, h = 800, screenIndex = 1, fullscreen = true }
        local framesBefore = #fake.windowFrames
        fake.pressHotkey("return", AC)
        ok(fake.fullscreenSets[#fake.fullscreenSets] == false and #fake.windowFrames == framesBefore,
            "fullscreen exits first, no frame change yet")
        fake.fireTimers("after", 0.5)
        lf = lastFrame()
        ok(lf.w == 750 and lf.h == 600, "the retry then applies the toggle")

        -- W-6: the HALF snaps get the same fullscreen prologue the header promises.
        -- AX refuses a frame write to a fullscreen window, so without it `left` was a
        -- silent no-op: no move, no alert, nothing in the log.
        do
            fake.focusedWindow = { x = 0, y = 0, w = 1000, h = 800, screenIndex = 1,
                                   fullscreen = true }
            local before = #fake.windowFrames
            fake.pressHotkey("left", AC)
            ok(fake.fullscreenSets[#fake.fullscreenSets] == false
                and #fake.windowFrames == before,
                "a half-snap on a fullscreen window exits fullscreen first (W-6)")
            fake.fireTimers("after", 0.5)
            lf = lastFrame()
            ok(lf.x == 0 and lf.w == 500 and lf.h == 800,
                "...and the retry then applies the left half")
        end

        -- W-7: "already maximized" is a tolerance, not float equality. An app that
        -- QUANTIZES the frame it accepts (Terminal, to character cells) settles a few
        -- px short of the screen on both axes; read with `==` it never counted as
        -- maximized, so the toggle re-maximized forever and the 75% state was
        -- unreachable for that app.
        do
            fake.focusedWindow = { x = 3, y = 4, w = 994, h = 793, screenIndex = 1 }
            fake.pressHotkey("return", AC)
            lf = lastFrame()
            ok(lf.x == 125 and lf.y == 100 and lf.w == 750 and lf.h == 600,
                "a quantized near-maximized window toggles to 75%, not back to max (W-7)")
        end

        -- throw to the bigger screen: least-distortion scale (1.5), per-axis offsets
        fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }
        fake.mousePos = { x = 150, y = 200 }
        fake.pressHotkey("]", AC)
        lf = lastFrame()
        ok(lf.w == 600 and lf.h == 450, "frame scales by the axis ratio closer to 1 (1.5)")
        ok(lf.x == 1200 and lf.y == 150, "position scales per axis onto the target screen")
        -- pointer tracks the WINDOW, not the raw screen offset: it was 12.5% across /
        -- 33% down the old window {100,100,400,300}, so on the new frame {1200,150,600,450}
        -- it lands at 1200+0.125*600, 150+(1/3)*450 = 1275, 300 -- INSIDE the window (the
        -- old screen-relative carry gave 1150, left of the window's x=1200 edge).
        ok(fake.mousePos.x == 1275 and fake.mousePos.y == 300, "pointer carried to its spot inside the window")
        ok(fake.mouseLocates[#fake.mouseLocates] == 2, "pointer flashed after the throw")

        -- and back, wrapping
        fake.focusedWindow.screenIndex = 2
        fake.pressHotkey("[", AC)
        ok(lastFrame().x >= 0 and lastFrame().x < 1000, "previous wraps back to the primary")

        -- a huge window clamps into the smaller target screen
        fake.focusedWindow = { x = 1000, y = 0, w = 2000, h = 1200, screenIndex = 2 }
        fake.pressHotkey("[", AC)
        lf = lastFrame()
        ok(lf.x == 0 and lf.y == 0 and lf.w == 1000 and lf.h == 800,
            "oversized throw clamps to the target screen")

        -- direction needs 3+ screens to be observable (with 2, next and prev both
        -- wrap to the other screen -- which is how a "previous" that never matched
        -- adjacentScreen's "prev" and fell through to next hid here): from the
        -- middle screen, ] must land right and [ must land left.
        do
            local saved = fake.screenList
            fake.screenList = {
                { x = -800, y = 0, w = 800, h = 600 },   -- left
                { x = 0, y = 0, w = 800, h = 600 },      -- middle (primary)
                { x = 800, y = 0, w = 800, h = 600 },    -- right
            }
            fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 2 }
            fake.pressHotkey("]", AC)
            ok(lastFrame().x >= 800, "] throws to the screen on the right")
            fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 2 }
            fake.pressHotkey("[", AC)
            ok(lastFrame().x < 0, "[ throws to the screen on the left")
            fake.screenList = saved
        end

        -- (The thirds are no longer hardcoded snap actions: they live as a QUICK-ADD
        -- recipe library in the placement editor -- a Swift-side affordance that appends a
        -- normal preset. Nothing to test at the Lua layer; the preset -> action apply path
        -- is covered by the presets block below.)

        -- swap the ACTIVE display's windows with another (no trigger -> runAction). Two
        -- displays: no choice to make, so it swaps immediately. Focus is on screen 1
        -- (activeIdx=1); each live window lands on the OTHER screen, rescaled; minimized
        -- and fullscreen windows are skipped.
        do
            fake.screenList = {
                { x = 0,    y = 0, w = 1000, h = 800 },      -- A (primary)
                { x = 1000, y = 0, w = 2000, h = 1200 },     -- B (bigger)
            }
            fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 } -- active = A
            fake.windows = {
                { id = 11, x = 100,  y = 100, w = 400, h = 300 },                    -- on A: moves
                { id = 12, x = 1200, y = 150, w = 600, h = 450 },                    -- on B: moves
                { id = 13, x = 200,  y = 200, w = 100, h = 100, minimized = true },  -- A, minimized: skip
                { id = 14, x = 1300, y = 100, w = 200, h = 200, fullscreen = true }, -- B, fullscreen: skip
            }
            fake.windowFrameSets = {}
            assert(registry.runAction("window_snap", "swap_screens"))
            local byId = {}
            for _, s in ipairs(fake.windowFrameSets) do byId[s.id] = s end
            ok(byId[11] and byId[12], "two displays swap immediately (no picker)")
            ok(not byId[13] and not byId[14], "minimized and fullscreen windows are skipped")
            -- w11 A->B: sx=2, sy=1.5; 1.5 is nearer 1 -> scale 1.5. 400x300 -> 600x450.
            -- pos: 1000+100*2=1200, 0+100*1.5=150.
            ok(byId[11].x == 1200 and byId[11].y == 150 and byId[11].w == 600 and byId[11].h == 450,
                "window on A lands on B, rescaled by the least-distortion axis")
            -- w12 B->A: sx=0.5, sy=2/3; 2/3 nearer 1 -> scale 2/3. 600x450 -> 400x300.
            -- pos: 0+(1200-1000)*0.5=100, 0+150*(2/3)=100.
            ok(byId[12].x == 100 and byId[12].y == 100 and byId[12].w == 400 and byId[12].h == 300,
                "window on B lands on A, rescaled back")
        end
        -- three displays: NO auto-swap -- the spatial picker opens to pick ANY two
        -- displays (the active one is only the sticky DEFAULT, passed LAST in preselect;
        -- no locked "current"). Each display carries its window count. Equal-size screens
        -- keep the geometry trivial (scale 1, +/-1000 shift).
        do
            fake.screenList = {
                { x = 0,    y = 0, w = 1000, h = 800, name = "Left"   },
                { x = 1000, y = 0, w = 1000, h = 800, name = "Middle" },
                { x = 2000, y = 0, w = 1000, h = 800, name = "Right"  },
            }
            fake.focusedWindow = { x = 1100, y = 100, w = 200, h = 150, screenIndex = 2 } -- active = Middle
            fake.windows = {
                { id = 41, x = 100,  y = 100, w = 200, h = 150 },   -- Left   (1 window)
                { id = 42, x = 1100, y = 100, w = 200, h = 150 },   -- Middle
                { id = 43, x = 2100, y = 200, w = 300, h = 200 },   -- Right  (1 window)
                { id = 44, x = 1200, y = 300, w = 200, h = 150 },   -- Middle (2nd -> count 2)
            }
            fake.windowFrameSets = {}
            local nPickers = #fake.displayPickers
            assert(registry.runAction("window_snap", "swap_screens"))
            ok(#fake.windowFrameSets == 0, "3 displays: nothing moves until the user confirms")
            ok(#fake.displayPickers == nPickers + 1, "3 displays: the spatial display picker opens")
            local dp = fake.displayPickers[#fake.displayPickers]
            ok(dp.selectCount == 2, "picker asks for a pair (selectCount 2)")
            ok(#dp.preselect == 2 and dp.preselect[#dp.preselect] == 2,
                "the active display (Middle) is the sticky default -- passed LAST in preselect")
            ok(#dp.displays == 3, "the whole arrangement is drawn")
            ok(dp.displays[1].windows == 1 and dp.displays[2].windows == 2 and dp.displays[3].windows == 1,
                "each display carries its (minimized/fullscreen-excluded) window count")
            -- the user is free to pick ANY two -- confirm Left + Right (neither is active)
            dp.userConfirm({ 1, 3 })
            local byId = {}
            for _, s in ipairs(fake.windowFrameSets) do byId[s.id] = s end
            ok(not byId[42] and not byId[44], "windows on the un-chosen display (Middle) are left alone")
            ok(byId[41] and byId[41].x == 2100 and byId[41].y == 100 and byId[41].w == 200 and byId[41].h == 150,
                "a window on the first picked display (Left) moves to the second (Right)")
            ok(byId[43] and byId[43].x == 100 and byId[43].y == 200 and byId[43].w == 300 and byId[43].h == 200,
                "a window on the second picked display (Right) moves to the first (Left)")
        end
        -- one display -> alerts, moves nothing, no picker
        do
            fake.screenList = { { x = 0, y = 0, w = 1000, h = 800 } }
            fake.focusedWindow = nil
            fake.windows = { { id = 31, x = 10, y = 10, w = 100, h = 100 } }
            fake.windowFrameSets = {}
            local before, nPickers = #fake.alerts, #fake.displayPickers
            assert(registry.runAction("window_snap", "swap_screens"))
            ok(#fake.windowFrameSets == 0 and #fake.alerts > before and #fake.displayPickers == nPickers,
                "swap with one display alerts, moves nothing, opens no picker")
            fake.windows = {}
        end
        -- swap without Accessibility: onboard (prompt + alert), don't silently no-op or
        -- open a picker full of "0 windows" displays.
        do
            fake.screenList = {
                { x = 0, y = 0, w = 1000, h = 800 },
                { x = 1000, y = 0, w = 2000, h = 1200 },
            }
            fake.focusedWindow = nil
            fake.windows = { { id = 61, x = 100, y = 100, w = 200, h = 150 } }
            fake.windowFrameSets = {}
            fake.axTrusted = false
            local before, nPickers = #fake.alerts, #fake.displayPickers
            assert(registry.runAction("window_snap", "swap_screens"))
            ok(#fake.windowFrameSets == 0 and #fake.alerts > before and #fake.displayPickers == nPickers,
                "swap without Accessibility onboards (alert), moves nothing, opens no picker")
            fake.axTrusted = true
            fake.windows = {}
        end

        -- no focused window -> plain alert (trusted)
        fake.focusedWindow = nil
        fake.pressHotkey("left", AC)
        ok(fake.alerts[#fake.alerts]:match("No focused window") ~= nil, "no window alerts plainly")

        registry.setEnabled("window_snap", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after window_snap test")

        -- PLACEMENT PRESETS (was T24p): the dynamicActions hook turns each saved preset
        -- (a JSON array in the feature's OWN option) into its own rebindable action
        -- (preset_<uuid>). Exercises expansion, apply via rectFromRatios, stable-id
        -- trigger survival across a re-register (what reload() does), rename relabel, and
        -- tolerance of a corrupt setting -- all in window_snap's own namespace.
        do
            local pjson = require("platform.json")
            local presetsKey = "hammerdeck.opt.window_snap.presets"

            -- Re-register window_snap from a FRESH module (clears the require cache like
            -- reload() does, so the static action list is expanded anew from the CURRENT
            -- setting -- never double-appended), then enable it.
            local function reregister()
                pcall(registry.setEnabled, "window_snap", false)
                registry.unregister("window_snap")
                package.loaded["features.window_snap"] = nil
                registry.register(require("features.window_snap"))
                registry.setEnabled("window_snap", true)
            end
            -- The described action row for an id, or nil.
            local function snapAction(id)
                for _, f in ipairs(registry.describe()) do
                    if f.id == "window_snap" then
                        for _, a in ipairs(f.actions) do
                            if a.id == id then return a end
                        end
                    end
                end
                return nil
            end

            fake.screenList    = { { x = 0, y = 0, w = 1200, h = 900 } }
            fake.focusedWindow = { x = 100, y = 100, w = 400, h = 300, screenIndex = 1 }

            -- (1) two presets -> two bindable actions (clean 0.5 fractions so the frame is exact)
            fake.settings[presetsKey] = pjson.encode({
                { id = "aaa", name = "Left half",         x = 0,   y = 0, w = 0.5, h = 1 },
                { id = "bbb", name = "Top-right quarter", x = 0.5, y = 0, w = 0.5, h = 0.5 },
            })
            reregister()
            ok(snapAction("preset_aaa") ~= nil and snapAction("preset_bbb") ~= nil,
                "each stored preset becomes a bindable action")
            ok(snapAction("preset_aaa").label == "Left half",
                "the action takes the preset's name as its label")
            ok(registry.isActionAutomatable("window_snap", "preset_aaa") == false,
                "a preset action is manual-only (not automatable)")
            ok(snapAction("preset_aaa").defaultTrigger == nil,
                "a preset ships dormant -- no default trigger (no uninvited hotkey grab)")
            -- The dynamic tag is what the config UI reads to HIDE these from the generic
            -- per-action trigger sections (they are bound inline in Saved placements); a
            -- built-in action must stay non-dynamic.
            ok(snapAction("preset_aaa").dynamic == true,
                "a preset action is tagged dynamic (config UI hides its duplicate trigger section)")
            ok(snapAction("left").dynamic == false,
                "a built-in action is not dynamic")

            -- (2) firing a preset applies its fractions via rectFromRatios
            assert(registry.runAction("window_snap", "preset_aaa"))
            local lf2 = lastFrame()
            ok(lf2.x == 0 and lf2.y == 0 and lf2.w == 600 and lf2.h == 900,
                "preset_aaa applies the left-half rectangle")
            assert(registry.runAction("window_snap", "preset_bbb"))
            lf2 = lastFrame()
            ok(lf2.x == 600 and lf2.y == 0 and lf2.w == 600 and lf2.h == 450,
                "preset_bbb applies the top-right-quarter rectangle")

            -- (3) stable id: a bound shortcut survives a re-register (reload's essence),
            -- because the trigger override keys on preset_<uuid>, not the array index.
            ok(registry.setTrigger("window_snap", "preset_aaa",
                { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "1" }),
                "a preset action binds a hotkey")
            reregister()
            local a = snapAction("preset_aaa")
            ok(a ~= nil and a.triggerOverridden == true and a.trigger and a.trigger.key == "1",
                "the bound shortcut survives a re-register (stable preset id)")

            -- (4) rename (same id, new name) -> new label, SAME binding
            fake.settings[presetsKey] = pjson.encode({
                { id = "aaa", name = "My Big Left",       x = 0,   y = 0, w = 0.5, h = 1 },
                { id = "bbb", name = "Top-right quarter", x = 0.5, y = 0, w = 0.5, h = 0.5 },
            })
            reregister()
            a = snapAction("preset_aaa")
            ok(a ~= nil and a.label == "My Big Left", "a rename updates the action label")
            ok(a.triggerOverridden == true, "a rename keeps the shortcut (the id is unchanged)")

            -- (5) tolerance: a corrupt setting yields NO preset actions, but the built-in
            -- snaps still bind (a bad value must never disable the feature)
            fake.settings[presetsKey] = "{ not json"
            reregister()
            ok(snapAction("preset_aaa") == nil, "a corrupt presets value drops the preset actions")
            ok(snapAction("left") ~= nil, "... and the built-in snaps still bind")

            -- clean up: clear the setting + the override, leave window_snap disabled.
            fake.settings[presetsKey] = nil
            fake.settings["hammerdeck.trigger.window_snap.preset_aaa"] = nil
            pcall(registry.setEnabled, "window_snap", false)
            ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
                "clean after window_snap presets test")
        end
    end,
}
