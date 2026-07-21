-- test/cases/tab_switcher_drift.lua -- the switcher must survive TAB DRIFT.
--
-- The reported bug ("tab moved -- try again a lot") was positional identity: the
-- feature keyed focus on (winId, tabIndex), which any reorder / close / window-move
-- invalidates, so a pick landed on the WRONG tab or falsely reported "moved". The
-- fix re-resolves each pick by STABLE IDENTITY (Chrome tab id first; else url + a
-- winId hint, preferring the listed tabIndex among equal-url matches), searching
-- all windows. Position is never PRIMARY identity -- but on a total url miss the
-- tab AT the listed (winId, tabIndex) is a last-resort tertiary: same host = a
-- Safari tab that navigated in place (honest success, its current url); different
-- host = a closed tab's neighbor (landed best-effort, reported as a miss). These
-- cases reproduce the exact drift the old logic failed on: each mutates the tab
-- set BETWEEN listing and the pick, then asserts the pick still lands on the
-- intended tab (or alerts only when it is truly gone). They are RED under
-- positional-primary matching and GREEN with id/url resolution (verified by
-- temporarily reverting fake.browserFocusTab to (winId,tabIndex)); cases 6/9/10
-- are likewise RED without the tabIndex preference / positional tertiary.
--
-- SCOPE: these assert against the FAKE resolver (fake_adapter.browserFocusTab), which
-- MIRRORS the real JXA in Native+Browser.swift -- they prove the feature passes stable
-- identity and the mirror resolves it, NOT the osascript seam itself. The real JXA is
-- guarded by the opt-in fidelity anchors testBrowserTabFocusByIdRealChrome /
-- testBrowserTabFocusByUrlRealSafari (IntegrationTests.swift); keep the two in sync.

return {
    id = "tab_switcher_drift",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.register(require("features.tab_switcher"))
        fake.runningApps["Google Chrome"] = true
        fake.runningApps["Safari"] = true

        local function rowOf(tch, text)
            for i, c in ipairs(tch.choices) do if c.text == text then return i end end
        end

        -- Reset the feature's cached choices, seed the LISTING tab set, and open the
        -- switcher -- each scenario starts from a clean, independent state.
        local function freshOpen(listing)
            registry.setEnabled("tab_switcher", false)
            fake.browserTabsByApp = listing
            registry.setEnabled("tab_switcher", true)
            fake.pressHotkey("tab", { "ctrl", "alt" })
            return fake.visibleChooser()
        end

        local function lastJump() return fake.tabJumps[#fake.tabJumps] end
        local function lastAlert() return fake.alerts[#fake.alerts] or "" end

        -- 1. REORDER: the target keeps its id but changes slot. Pick must follow the
        --    id, not the old slot (which now holds a different tab).
        local tch = freshOpen({ ["Google Chrome"] = {
            { title = "A", url = "https://a/", winId = 1, tabIndex = 1, id = 1, visible = true },
            { title = "B", url = "https://b/", winId = 1, tabIndex = 2, id = 2, visible = true },
            { title = "C", url = "https://c/", winId = 1, tabIndex = 3, id = 3, visible = true },
        }, ["Safari"] = {} })
        fake.browserTabsByApp["Google Chrome"] = {   -- reordered to C, A, B
            { title = "C", url = "https://c/", winId = 1, tabIndex = 1, id = 3, visible = true },
            { title = "A", url = "https://a/", winId = 1, tabIndex = 2, id = 1, visible = true },
            { title = "B", url = "https://b/", winId = 1, tabIndex = 3, id = 2, visible = true },
        }
        tch.userSelect(rowOf(tch, "B"))
        ok(lastJump().resolved and lastJump().resolved.title == "B",
            "reorder: pick follows the tab id to B, not the old slot (now A)")

        -- 2. CLOSE-BEFORE: closing a tab ahead of the target shifts every later slot;
        --    the old index would run off the end. Id resolution still finds it.
        tch = freshOpen({ ["Google Chrome"] = {
            { title = "A", url = "https://a/", winId = 1, tabIndex = 1, id = 1, visible = true },
            { title = "B", url = "https://b/", winId = 1, tabIndex = 2, id = 2, visible = true },
            { title = "C", url = "https://c/", winId = 1, tabIndex = 3, id = 3, visible = true },
        }, ["Safari"] = {} })
        fake.browserTabsByApp["Google Chrome"] = {   -- A closed; B,C shift down
            { title = "B", url = "https://b/", winId = 1, tabIndex = 1, id = 2, visible = true },
            { title = "C", url = "https://c/", winId = 1, tabIndex = 2, id = 3, visible = true },
        }
        tch.userSelect(rowOf(tch, "C"))
        ok(lastJump().resolved and lastJump().resolved.title == "C",
            "close-before: pick still lands on C though its slot changed / index would overrun")

        -- 3. CROSS-WINDOW MOVE: the tab is dragged to another window (winId changes).
        --    winId is only a hint; the id finds it wherever it went.
        tch = freshOpen({ ["Google Chrome"] = {
            { title = "X", url = "https://x/", winId = 1, tabIndex = 1, id = 5, visible = true },
        }, ["Safari"] = {} })
        fake.browserTabsByApp["Google Chrome"] = {   -- X now lives in window 2
            { title = "X", url = "https://x/", winId = 2, tabIndex = 1, id = 5, visible = true },
        }
        tch.userSelect(rowOf(tch, "X"))
        ok(lastJump().resolved and lastJump().resolved.winId == 2,
            "cross-window move: id resolution follows the tab into window 2")

        -- 4. GENUINELY GONE: the target was actually closed. This is the ONE case
        --    where "moved" is correct -- resolution finds nothing, we alert + relist.
        tch = freshOpen({ ["Google Chrome"] = {
            { title = "A", url = "https://a/", winId = 1, tabIndex = 1, id = 1, visible = true },
            { title = "B", url = "https://b/", winId = 1, tabIndex = 2, id = 2, visible = true },
        }, ["Safari"] = {} })
        fake.browserTabsByApp["Google Chrome"] = {   -- B closed for real
            { title = "A", url = "https://a/", winId = 1, tabIndex = 1, id = 1, visible = true },
        }
        tch.userSelect(rowOf(tch, "B"))
        ok(lastJump().resolved == nil and lastAlert():match("moved") ~= nil,
            "genuinely closed: no match -> the 'moved' alert fires")

        -- 5. CHROME DUP-URL: two tabs share a url but have distinct ids. The pick must
        --    honor the EXACT id, not just land on the first url match.
        tch = freshOpen({ ["Google Chrome"] = {
            { title = "Dup-A", url = "https://dup/", winId = 1, tabIndex = 1, id = 10, visible = true },
            { title = "Dup-B", url = "https://dup/", winId = 1, tabIndex = 2, id = 20, visible = true },
        }, ["Safari"] = {} })
        tch.userSelect(rowOf(tch, "Dup-B"))
        ok(lastJump().resolved and lastJump().resolved.id == 20,
            "chrome dup-url: the exact tab id wins over a bare url match")

        -- 6. SAFARI DUP-URL (no id): Safari tabs have id 0, so resolution falls back
        --    to the url -- and among equal-url matches in the hinted window, the
        --    LISTED tabIndex wins, so each duplicate is individually reachable
        --    (first-match would send every pick to S1).
        tch = freshOpen({ ["Google Chrome"] = {}, ["Safari"] = {
            { title = "S1", url = "https://s/", winId = 9, tabIndex = 1, id = 0, visible = true },
            { title = "S2", url = "https://s/", winId = 9, tabIndex = 2, id = 0, visible = true },
        } })
        local before = #fake.alerts
        tch.userSelect(rowOf(tch, "[Safari] S2"))
        ok(lastJump().resolved and lastJump().resolved.tabIndex == 2
            and #fake.alerts == before,
            "safari dup-url: the listed tabIndex picks THAT duplicate, no spurious 'moved'")

        -- 7. NO MID-INTERACTION DISRUPTION, then deferred freshness. A background
        --    relist must NEVER re-setChoices the LIVE chooser: natively that runs
        --    applyFilter -> selectFirstValid, snapping the selection back to row 1, so
        --    a held release-to-jump would land on the wrong tab. Instead it stages the
        --    fresh list for the NEXT open, so a closed tab clears one open later --
        --    never by yanking the list the user is looking at.
        tch = freshOpen({ ["Google Chrome"] = {
            { title = "A", url = "https://a/", winId = 1, tabIndex = 1, id = 1, visible = true },
            { title = "B", url = "https://b/", winId = 1, tabIndex = 2, id = 2, visible = true },
        }, ["Safari"] = {} })
        ok(#tch.choices == 2, "freshness: both tabs listed initially")
        tch.userSelect(rowOf(tch, "A"))              -- pick A -> the switcher closes
        fake.browserTabsByApp["Google Chrome"] = {   -- B closed while the switcher is shut
            { title = "A", url = "https://a/", winId = 1, tabIndex = 1, id = 1, visible = true },
        }
        tch.setChoicesCalls = 0
        fake.pressHotkey("tab", { "ctrl", "alt" })   -- reopen (cached path)
        tch = fake.visibleChooser()
        ok(tch and tch.setChoicesCalls == 1,
            "reopen sets the visible list ONCE (the show); the background relist stages, never re-sets it")
        ok(#tch.choices == 2,
            "the live list is NOT swapped mid-open -- the just-closed tab is still shown (stable, not yanked)")
        tch.userSelect(rowOf(tch, "A"))              -- dismiss again
        fake.pressHotkey("tab", { "ctrl", "alt" })   -- the NEXT open promotes the staged relist
        tch = fake.visibleChooser()
        ok(tch and #tch.choices == 1 and rowOf(tch, "B") == nil,
            "deferred freshness: the next open promotes the staged relist; the closed tab is gone")

        -- 8. FLICK-TO-PREVIOUS survives the jump. After flicking to P, the NEXT open
        --    must rank P first (now current) and preselect row 2 = C (the tab you were
        --    on), so a second flick returns you. This requires re-ranking by CURRENT
        --    MRU at SHOW time: the cached/promoted list still carries its pre-jump
        --    order, so without the re-rank row 2 would still be P and the flick-back
        --    would jump you nowhere.
        registry.setEnabled("tab_switcher", false)
        local now = fake.now()
        fake.files["/fake/data/tab_switcher/mru.json"] = require("platform.json").encode({
            ["Google Chrome"] = {
                ["https://c/"] = now - 5, ["https://p/"] = now - 10, ["https://q/"] = now - 20,
            },
        })
        fake.browserTabsByApp = { ["Google Chrome"] = {
            { title = "C", url = "https://c/", winId = 1, tabIndex = 1, id = 1, visible = true },
            { title = "P", url = "https://p/", winId = 1, tabIndex = 2, id = 2, visible = true },
            { title = "Q", url = "https://q/", winId = 1, tabIndex = 3, id = 3, visible = true },
        }, ["Safari"] = {} }
        registry.setEnabled("tab_switcher", true)
        fake.pressHotkey("tab", { "ctrl", "alt" })   -- open1
        tch = fake.visibleChooser()
        ok(tch.choices[1].text == "C" and tch.choices[2].text == "P",
            "flick: MRU order is [C, P, Q]; the preselected row 2 is the previous tab P")
        tch.userSelect(2)                            -- flick to P -> jump, restamps P as newest
        fake.pressHotkey("tab", { "ctrl", "alt" })   -- open2 (same live instance)
        tch = fake.visibleChooser()
        ok(tch.choices[1].text == "P", "after the jump, P (now current) re-ranks to the top")
        ok(tch.selectedRow == 2 and tch.choices[2].text == "C",
            "flick-back: row 2 is now C, the tab you were on -- a second flick returns you")

        -- 9. SAFARI IN-PLACE NAVIGATION (same host): the tab NAVIGATED since listing
        --    (its url matches nowhere), but it still sits at its listed (winId,
        --    tabIndex) and stayed on the same site. The positional tertiary must
        --    land it and report its CURRENT url -- an honest success, never a false
        --    "moved". This was the old positional key's ONE win over pure url
        --    resolution; the tertiary restores it.
        tch = freshOpen({ ["Google Chrome"] = {}, ["Safari"] = {
            { title = "Doc p1", url = "https://s/page1", winId = 9, tabIndex = 1, id = 0, visible = true },
            { title = "Other", url = "https://t/", winId = 9, tabIndex = 2, id = 0, visible = true },
        } })
        fake.browserTabsByApp["Safari"] = {   -- p1 navigated to p2 in place
            { title = "Doc p2", url = "https://s/page2", winId = 9, tabIndex = 1, id = 0, visible = true },
            { title = "Other", url = "https://t/", winId = 9, tabIndex = 2, id = 0, visible = true },
        }
        before = #fake.alerts
        tch.userSelect(rowOf(tch, "[Safari] Doc p1"))
        ok(lastJump().resolved and lastJump().resolved.url == "https://s/page2"
            and #fake.alerts == before,
            "safari in-place navigation: the positional tertiary lands the CURRENT url, no false 'moved'")

        -- 10. SAFARI CLOSED-TAB NEIGHBOR (different host): the listed tab is gone
        --     and an unrelated site now sits at its position. Land there best-effort
        --     (near where the tab was) but report the HONEST miss -- alert + relist,
        --     never a silent wrong jump stamped into MRU.
        tch = freshOpen({ ["Google Chrome"] = {}, ["Safari"] = {
            { title = "Gone", url = "https://gone/", winId = 9, tabIndex = 1, id = 0, visible = true },
            { title = "Neighbor", url = "https://neighbor/", winId = 9, tabIndex = 2, id = 0, visible = true },
        } })
        fake.browserTabsByApp["Safari"] = {   -- Gone closed; Neighbor shifted into slot 1
            { title = "Neighbor", url = "https://neighbor/", winId = 9, tabIndex = 1, id = 0, visible = true },
        }
        tch.userSelect(rowOf(tch, "[Safari] Gone"))
        ok(lastJump().resolved == nil
            and lastJump().missLanding and lastJump().missLanding.url == "https://neighbor/"
            and lastAlert():match("moved") ~= nil,
            "safari closed neighbor: lands at the old position but reports the honest miss")

        registry.setEnabled("tab_switcher", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
            "clean after tab_switcher_drift test")
    end,
}
