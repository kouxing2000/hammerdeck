-- test/cases/window_deck_pure.lua -- window_deck's PURE sibling modules, tested directly
-- (no deck, no adapter handles) now that the stateful controller's decision logic lives in
-- them: focus.classify (the 5-way reconcile dispatch, with its precedence), identity (the
-- wid->title key ladder, onScreen/frameFar, matchMembers' wid-beats-title restore), colors
-- (free-palette dealing around a stored recolor), and store (the last-deck save/read/json
-- round-trip that carries the PRIMARY wid identity end-to-end).
--
-- Migrated from run.lua T25e + T25e-store (RUN_LUA_SPLIT_SPEC Phase 2). Pure module unit
-- tests: no feature registration, no fake fixtures -- like windows_geometry/json_codec, the
-- case sources only `ok` from the harness. freshWorld() re-purges the cached feature modules
-- before each run, and the handle tripwire after is trivially clean (nothing was bound).

return {
    id = "window_deck_pure",
    ---@param t Harness
    run = function(t)
        local ok = t.ok

        do
            local ident  = require("features.window_deck.identity")
            local colors = require("features.window_deck.colors")
            local focus  = require("features.window_deck.focus")

            -- focus.classify: the pure 5-way decision core reconcile dispatches on, run
            -- AFTER the shell handles settling + presence. Every row of the table,
            -- including precedence (isHero beats listed/heroMode; peek beats all).
            ok(focus.classify({ hasMember = false }) == "peek",
                "classify: no deck window focused -> peek")
            ok(focus.classify({ hasMember = true, isHero = true, listed = true, heroMode = true })
                == "return", "classify: the current hero regained front -> return")
            ok(focus.classify({ hasMember = true, isHero = true, listed = false, heroMode = false })
                == "return", "classify: isHero wins even when not listed / hero off")
            ok(focus.classify({ hasMember = true, isHero = false, listed = false, heroMode = true })
                == "ignore", "classify: a deck window not yet listed -> ignore (race)")
            ok(focus.classify({ hasMember = true, isHero = false, listed = true, heroMode = false })
                == "gridFocus", "classify: Hero-off mode -> gridFocus, never promote")
            ok(focus.classify({ hasMember = true, isHero = false, listed = true, heroMode = true })
                == "promote", "classify: non-hero deck window in Hero mode -> promote")

            -- keyOf identity ladder: a real wid keys by wid (survives retitles); a
            -- missing/zero wid falls back to bundleID+title. The two spaces never
            -- collide (distinct \0-prefixes), and a retitle changes ONLY the title key.
            ok(ident.keyOf({ bundleID = "com.x", wid = 42, title = "A" })
                == ident.widKey("com.x", 42), "keyOf uses the wid key when wid is real")
            ok(ident.keyOf({ bundleID = "com.x", wid = 42, title = "A" })
                == ident.keyOf({ bundleID = "com.x", wid = 42, title = "RENAMED" }),
                "keyOf is title-independent when keyed by wid (survives retitle)")
            ok(ident.keyOf({ bundleID = "com.x", wid = 0, title = "A" })
                == ident.titleKey("com.x", "A"), "keyOf falls back to the title key when wid is 0")
            ok(ident.widKey("com.x", 1) ~= ident.titleKey("com.x", "1"),
                "wid and title key spaces never collide")

            -- onScreen: window CENTRE inside the screen rect.
            local scr = { x = 0, y = 0, w = 1000, h = 800 }
            ok(ident.onScreen({ x = 400, y = 300, w = 200, h = 200 }, scr),
                "onScreen true when centre is inside")
            ok(not ident.onScreen({ x = 1200, y = 300, w = 200, h = 200 }, scr),
                "onScreen false when centre is outside")

            -- frameFar: >6px on any axis is "far" (drives the Rearrange dirty flag).
            ok(not ident.frameFar({ x = 0, y = 0, w = 10, h = 10 }, { x = 5, y = 0, w = 10, h = 10 }),
                "frameFar false within the 6px threshold")
            ok(ident.frameFar({ x = 0, y = 0, w = 10, h = 10 }, { x = 20, y = 0, w = 10, h = 10 }),
                "frameFar true past the threshold")
            ok(not ident.frameFar(nil, { x = 0 }), "frameFar false when a frame is missing")

            -- colors.assign: a recolored app (stored) keeps its color; others deal the
            -- next FREE palette color, so no two windows share a color until exhaustion.
            local wins = {
                { bundleID = "com.a" }, { bundleID = "com.b" }, { bundleID = "com.c" },
            }
            local pal = colors.PALETTE
            local dealt = colors.assign(wins, { ["com.b"] = pal[5] })
            ok(dealt[2] == pal[5], "assign keeps a recolored app's stored color")
            ok(dealt[1] ~= dealt[2] and dealt[1] ~= dealt[3] and dealt[2] ~= dealt[3],
                "assign deals distinct colors and never reuses the stored one")
            ok(dealt[1] ~= pal[5] and dealt[3] ~= pal[5],
                "assign skips the palette color already taken by the stored app")
            -- The stored color applies to the FIRST window of that app; a second
            -- same-app window falls through to positional dealing (seenApp guard), so
            -- it gets a DIFFERENT color -- the documented per-app-first-window rule.
            local sameApp = colors.assign({ { bundleID = "com.a" }, { bundleID = "com.a" } },
                { ["com.a"] = pal[1] })
            ok(sameApp[1] == pal[1], "assign gives the stored app's first window its stored color")
            ok(sameApp[2] ~= pal[1], "a second same-app window deals a fresh positional color")

            -- matchMembers: rebuild a saved deck from the live windows (drives "restore
            -- last deck"). wid matches within a session (survives a retitle); title
            -- matches across an app restart (new wid, same title); each live window is
            -- claimed once; a missing member simply drops (a partial restore).
            local saved = {
                { bundleID = "com.a", title = "A1", wid = 11 },
                { bundleID = "com.a", title = "A2", wid = 12 },
                { bundleID = "com.b", title = "B",  wid = 21 },
            }
            -- same session: A1 retitled to "A1*" but its wid still matches
            local inSession = ident.matchMembers(saved, {
                { id = 1, bundleID = "com.a", title = "A1*", wid = 11 },
                { id = 2, bundleID = "com.a", title = "A2",  wid = 12 },
                { id = 3, bundleID = "com.b", title = "B",   wid = 21 },
            })
            ok(#inSession == 3, "matchMembers: all three match in-session (wid survives a retitle)")
            -- after a restart: fresh wids, titles carry the match; B is closed -> 2 of 3
            local crossRestart = ident.matchMembers(saved, {
                { id = 1, bundleID = "com.a", title = "A1", wid = 91 },
                { id = 2, bundleID = "com.a", title = "A2", wid = 92 },
            })
            ok(#crossRestart == 2 and crossRestart[1].title == "A1" and crossRestart[2].title == "A2",
                "matchMembers: cross-restart title match; a closed window drops (2 of 3)")
            -- two same-app saved members must not both collapse onto one live window
            ok(#ident.matchMembers(
                { { bundleID = "com.a", title = "A1", wid = 0 }, { bundleID = "com.a", title = "A1", wid = 0 } },
                { { id = 1, bundleID = "com.a", title = "A1", wid = 0 } }) == 1,
                "matchMembers claims each live window once (no collapse)")
            -- wid BEATS title: two same-app windows share a title in one session, listed
            -- wid-descending. A single greedy (wid OR title) pass would bind the first
            -- saved member to the wrong window through the title; the wid-first split
            -- binds each to its own wid regardless of list order.
            local mt = ident.matchMembers(
                { { bundleID = "com.a", title = "T", wid = 100 },
                  { bundleID = "com.a", title = "T", wid = 200 } },
                { { id = 200, bundleID = "com.a", title = "T", wid = 200 },   -- B's window first
                  { id = 100, bundleID = "com.a", title = "T", wid = 100 } })
            ok(#mt == 2 and mt[1].id == 100 and mt[2].id == 200,
                "matchMembers: wid wins over title (each twin binds to its own wid, not the title-first hit)")
            -- a member with neither a real wid nor a title can't be identified
            ok(#ident.matchMembers(
                { { bundleID = "com.a", title = "", wid = 0 } },
                { { id = 1, bundleID = "com.a", title = "", wid = 0 } }) == 0,
                "matchMembers: an unidentifiable (no wid, no title) member never matches")
        end

        -- the last-deck round-trip: PROVE the PRIMARY wid identity flows through
        -- save -> json -> read -> PASS 1 (matchMembers), the path quadWindows()'s
        -- title-only fixtures in the integration case never exercise.
        do
            local store = require("features.window_deck.store")
            local ident = require("features.window_deck.identity")
            local mem = {}
            local persist = store.new({ getState = function(k) return mem[k] end,
                                        setState = function(k, v) mem[k] = v end })
            ok(persist.readLastDeck() == nil, "readLastDeck: nil when nothing is stored")
            persist.saveLastDeck("Main", {
                { bundleID = "com.a", title = "Doc A", wid = 4242 },
                { bundleID = "com.b", title = "Doc B", wid = 4243 },
            })
            local last = persist.readLastDeck()
            ok(last and last.screen == "Main" and #last.members == 2,
                "saveLastDeck/readLastDeck round-trips the screen + membership")
            ok(last.members[1].wid == 4242 and last.members[1].title == "Doc A",
                "a member's wid + title survive the json round-trip")
            -- PASS 1 binds by the round-tripped wid even after a RETITLE -- only wid
            -- (not title) could carry this match, so it proves the primary path E2E.
            local matched = ident.matchMembers(last.members, {
                { id = 1, bundleID = "com.a", title = "Doc A -- edited", wid = 4242 },  -- retitled
                { id = 2, bundleID = "com.b", title = "Doc B",          wid = 4243 },
            })
            ok(#matched == 2 and matched[1].id == 1,
                "restored wid matches through save/read despite a retitle (PASS 1 proven end-to-end)")
            -- a one-member store is rejected (a deck needs two)
            persist.saveLastDeck("Main", { { bundleID = "com.a", title = "solo", wid = 7 } })
            ok(persist.readLastDeck() == nil, "readLastDeck rejects a < 2 member record")
        end
    end,
}
