-- test/cases/memory_room.lua -- memory_room: a memory palace for ONE app's
-- windows. Two halves:
-- 1. room.lua, the pure schema both writers share (the running feature and the
--    Settings page via readerCall): decode's forgiveness rules, v1 records, and
--    arrange() -- a window keeps its spot across opens, across a
--    retitle (wid) and across an app restart (title), new windows take free
--    slots, closed windows' slots are reused only when every slot is taken.
-- 2. The live flow over the fake: Hyper+L lists the FRONT app's windows only,
--    draws them at once, a click focuses the window it names, a drag keeps
--    the new spot, Escape closes the room, and the three empty cases
--    (no Accessibility, app not answering, no windows) each say their own thing.
--
-- Hermetic: registers memory_room itself; state lives in fake.settings.

local STATE = "hammerdeck.state.memory_room.room"

---@param id integer
---@param wid integer
---@param title string
---@param bundle string|nil
---@return table
local function win(id, wid, title, bundle)
    return { id = id, wid = wid, title = title, appName = "Code", bundleID = bundle or "com.code",
             x = 0, y = 0, w = 800, h = 600 }
end

return {
    id = "memory_room",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry
        local HYP = { "cmd", "alt", "ctrl" }
        local R = require("features.memory_room.room")
        local json = require("platform.json")
        local function front(name, bundleId) fake.frontmost, fake.frontmostId = name, bundleId end
        local function entries(raw, app) return R.decode(raw).apps[app] or {} end

        -- ===== decode =====
        do
            local room = R.decode(nil)
            ok(room.image == nil and next(room.apps) == nil, "no record: an empty room")
            ok(next(R.decode("not json").apps) == nil, "an unreadable record: an empty room")
            local v1 = R.decode('{"v":1,"image":"neon","showKeys":true,"pins":[{"id":"p1","key":"d","x":0.3,"y":0.5,"apps":["x"]}]}')
            ok(v1.image == "neon" and next(v1.apps) == nil,
                "a v1 record (apps in places) keeps its picture; its places are dropped")
            local r = R.decode(json.encode(json.asObject({ v = 2, apps = json.asObject({ ["com.code"] = json.asArray({
                json.asObject({ wid = 11, title = "a", x = 0.2, y = 0.2, key = "w" }),
                json.asObject({ wid = 0, title = "", x = 0.5, y = 0.5 }),
                json.asObject({ wid = 11, title = "dup", x = 0.9, y = 0.9 }),
                json.asObject({ wid = 12, title = "b", x = 2, y = -1, key = "w" }),
            }) }) })))
            local list = r.apps["com.code"]
            ok(#list == 2, "a window with nothing to find it by, and a second entry for one wid, are dropped")
            ok(list[2].x == 1 and list[2].y == 0, "spots are clamped into the picture")
            local rewritten = R.encode(r)
            ok(not rewritten:find('"key"', 1, true) and not R.encode(v1):find("showKeys", 1, true),
                "fields the schema does not know (a window's letter, the letters setting) are not written back")
            ok(R.encode(R.empty()):find('"apps":{}', 1, true) ~= nil,
                "an empty apps table is written as an object, so a bundle id can join it later")
        end

        -- ===== arrange: a window keeps its spot =====
        do
            local live = { win(1, 101, "api — Code"), win(2, 102, "web — Code"), win(3, 103, "docs — Code") }
            local a = R.arrange(nil, "com.code", live)
            ok(#a.spots == 3 and a.spots[1].new and a.spots[3].new, "three windows the room has never seen")
            ok(a.spots[1].entry.x == R.SLOTS[1].x and a.spots[1].entry.y == R.SLOTS[1].y
                and a.spots[2].entry.x == R.SLOTS[2].x and a.spots[3].entry.x == R.SLOTS[3].x,
                "they take the first free slots (the furniture), most recently focused first")
            ok(#entries(a.json, "com.code") == 3, "and the room remembers all three")

            -- the next open, listed in another order: same spots
            local again = R.arrange(a.json, "com.code", { win(9, 103, "docs — Code"), win(8, 101, "api — Code"),
                                                         win(7, 102, "web — Code") })
            local by = {}
            for _, s in ipairs(again.spots) do by[s.entry.wid] = s end
            ok(not by[101].new and by[101].entry.x == R.SLOTS[1].x
                and by[103].entry.x == R.SLOTS[3].x, "the next open: every window where it was")
            ok(entries(again.json, "com.code")[1].wid == 103, "recency: this open's windows lead, in list order")

            -- a retitle (same wid) keeps the spot and takes the new title
            local retitled = R.arrange(a.json, "com.code", { win(1, 101, "api (edited) — Code") })
            ok(retitled.spots[1].entry.x == R.SLOTS[1].x and retitled.spots[1].entry.title == "api (edited) — Code",
                "a retitled window keeps its spot (found by wid) and the room learns the new title")

            -- the app restarted: new wids, same titles
            local restarted = R.arrange(a.json, "com.code", { win(4, 201, "web — Code"), win(5, 202, "api — Code") })
            local rb = {}
            for _, s in ipairs(restarted.spots) do rb[s.entry.title] = s end
            ok(rb["api — Code"].entry.x == R.SLOTS[1].x and rb["api — Code"].entry.wid == 202
                and rb["web — Code"].entry.x == R.SLOTS[2].x,
                "after an app restart a window is found by title, and known by its new wid from then on")
            ok(#entries(restarted.json, "com.code") == 3, "the window not open now is remembered, not forgotten")

            -- a new window does not take a closed window's slot while a free one is left
            local closedOne = R.arrange(a.json, "com.code", { win(1, 101, "api — Code"), win(6, 106, "new — Code") })
            local fresh
            for _, s in ipairs(closedOne.spots) do if s.new then fresh = s end end
            ok(fresh and fresh.entry.x == R.SLOTS[4].x and fresh.entry.y == R.SLOTS[4].y,
                "a new window takes the next FREE slot, not one a closed window still holds")

            -- other apps are untouched
            local other = R.arrange(a.json, "com.term", { win(1, 301, "zsh", "com.term") })
            ok(#entries(other.json, "com.code") == 3 and other.spots[1].entry.x == R.SLOTS[1].x,
                "each app has its own room: another app starts at the first slot, and the first keeps its windows")
        end

        -- ===== arrange: full rooms =====
        do
            local live = {}
            for i = 1, #R.SLOTS do live[i] = win(i, 1000 + i, "w" .. i) end
            local full = R.arrange(nil, "com.code", live)
            local newOne = R.arrange(full.json, "com.code", { win(99, 5000, "brand new") })
            ok(newOne.spots[1].entry.x == R.SLOTS[1].x and newOne.spots[1].entry.y == R.SLOTS[1].y,
                "every slot taken by closed windows: the first is reused")
            ok(#entries(newOne.json, "com.code") == #R.SLOTS, "and the closed window that held it is forgotten")

            live = {}
            for i = 1, #R.SLOTS + 2 do live[i] = win(i, 2000 + i, "v" .. i) end
            local crowded = R.arrange(nil, "com.code", live)
            ok(#crowded.spots == #R.SLOTS + 2, "more open windows than slots: every one is still drawn (some share)")

            local raw = nil
            for i = 1, R.MAX_WINDOWS + 5 do raw = R.arrange(raw, "com.code", { win(i, 3000 + i, "x" .. i) }).json end
            ok(#entries(raw, "com.code") == #R.SLOTS,
                "one window at a time: closed windows give up their slots, so the room holds one per slot")
            ok(entries(raw, "com.code")[1].wid == 3000 + R.MAX_WINDOWS + 5, "the newest leads")

            live = {}
            for i = 1, R.MAX_WINDOWS + 5 do live[i] = win(i, 4000 + i, "z" .. i) end
            ok(#entries(R.arrange(nil, "com.code", live).json, "com.code") == R.MAX_WINDOWS,
                "more open windows than the cap: the least recently focused are not remembered")
        end

        -- ===== names: the part next to the app's name, without the noise =====
        do
            local CH = "Google Chrome"
            ok(R.nameOf("Today · Dashboard - Google Chrome - Work", CH) == "Today · Dashboard",
                "Chrome: the page, not the profile after the app's name")
            ok(R.nameOf("An answer - Quora - High memory usage - 871 MB - Google Chrome", CH) == "Quora",
                "Chrome's memory note and sizes are not a name")
            ok(R.nameOf("Release notes | Example Docs - Google Chrome", CH) == "Example Docs",
                "a ' | ' separates parts too")
            ok(R.nameOf("room.lua — hammerdeck", "Code") == "hammerdeck",
                "a title that does not name the app: its last part (VS Code's project)")
            ok(R.nameOf("hammerdeck — -zsh — 80×24", "Terminal") == "hammerdeck", "a terminal's shell and size are not a name")
            ok(R.nameOf("notes.txt — Edited", "TextEdit") == "notes.txt", "a document's 'Edited' is not a name")
            ok(R.nameOf("Google Chrome", CH) == "Google Chrome", "nothing but the app's name: the title itself")
            ok(R.nameOf("Sign in - Google Accounts - Google Chrome (Incognito)", CH) == "Google Accounts",
                "the app's name with a note after it (an Incognito window) is still the app's name")
        end

        -- ===== a window that comes back =====
        do
            local a = R.arrange(nil, "com.code", { win(1, 101, "room.lua — hammerdeck"), win(2, 102, "a.ts — web") })
            -- VS Code restarted: new wids, and each window has another file open
            local b = R.arrange(a.json, "com.code", { win(3, 201, "b.ts — web"), win(4, 202, "init.lua — hammerdeck") })
            local by = {}
            for _, sp in ipairs(b.spots) do by[sp.entry.wid] = sp end
            ok(not by[202].new and by[202].entry.x == R.SLOTS[1].x and not by[201].new and by[201].entry.x == R.SLOTS[2].x,
                "after an app restart a window is found by its name (the project), not only its exact title")
            ok(#entries(b.json, "com.code") == 2, "and nothing is remembered twice")
        end

        -- ===== spots the user placed are kept; icons never land on each other =====
        do
            local live = {}
            for i = 1, #R.SLOTS do live[i] = win(i, 1000 + i, "w" .. i) end
            local full = R.arrange(nil, "com.code", live)
            local raw = full.json
            -- the user drags the window on the first slot a little, and closes everything
            raw = R.move(raw, "com.code", "w1001", R.SLOTS[1].x + 0.01, R.SLOTS[1].y).json
            local e1
            for _, e in ipairs(entries(raw, "com.code")) do if e.wid == 1001 then e1 = e end end
            ok(e1 and e1.placed, "a dragged window is marked as placed by the user")
            local n = R.arrange(raw, "com.code", { win(99, 5000, "brand new") })
            ok(n.spots[1].entry.x == R.SLOTS[2].x and n.spots[1].entry.y == R.SLOTS[2].y,
                "a new window skips the slot a closed window was placed in, and reuses the next automatic one")
            local kept
            for _, e in ipairs(entries(n.json, "com.code")) do if e.wid == 1001 then kept = e end end
            ok(kept and kept.x == R.SLOTS[1].x + 0.01, "the placed window's spot waits for it while it is closed")

            -- every slot placed by hand: a new window finds a gap rather than a placed spot
            raw = full.json
            for i = 1, #R.SLOTS do raw = R.move(raw, "com.code", "w" .. (1000 + i), R.SLOTS[i].x, R.SLOTS[i].y).json end
            local g = R.arrange(raw, "com.code", { win(98, 6000, "another") }).spots[1].entry
            local clear = true
            for _, sl in ipairs(R.SLOTS) do
                if math.abs(sl.x - g.x) < R.FOOT.w and math.abs(sl.y - g.y) < R.FOOT.h then clear = false end
            end
            ok(clear, "every slot placed by hand: the new window takes a gap no icon covers")

            -- a window dragged near (not onto) a slot still keeps new windows off it
            local near = R.arrange(nil, "com.code", { win(1, 101, "one"), win(2, 102, "two") })
            local moved = R.move(near.json, "com.code", "w102", R.SLOTS[3].x + 0.08, R.SLOTS[3].y).json
            local third = R.arrange(moved, "com.code", { win(1, 101, "one"), win(2, 102, "two"), win(3, 103, "three") })
            local e3
            for _, sp in ipairs(third.spots) do if sp.entry.wid == 103 then e3 = sp.entry end end
            ok(e3 and e3.x == R.SLOTS[2].x and e3.y == R.SLOTS[2].y,
                "the slot the dragged window left is free again")
            local fourth = R.arrange(third.json, "com.code", { win(4, 104, "four") })
            ok(fourth.spots[1].entry.x == R.SLOTS[4].x and fourth.spots[1].entry.y == R.SLOTS[4].y,
                "a slot another icon half covers is skipped, not drawn over")

            -- the cap forgets automatic spots before placed ones
            local capped = full.json
            capped = R.move(capped, "com.code", "w" .. (1000 + #R.SLOTS), 0.5, 0.5).json   -- the oldest, placed
            local many = {}
            for i = 1, R.MAX_WINDOWS do many[i] = win(i, 7000 + i, "m" .. i) end
            local after = R.arrange(capped, "com.code", many)
            local stillThere = false
            for _, e in ipairs(entries(after.json, "com.code")) do
                if e.wid == 1000 + #R.SLOTS then stillThere = true end
            end
            ok(stillThere and #entries(after.json, "com.code") == R.MAX_WINDOWS,
                "over the cap, the forgotten windows are automatic ones: a placed spot stays")
        end

        -- ===== two windows, one spot: open windows are never drawn on each other =====
        do
            local function spotOf(a, wid)
                for _, sp in ipairs(a.spots) do if sp.entry.wid == wid then return sp end end
            end
            local function apart(p, q)
                return math.abs(p.x - q.x) >= R.FOOT.w or math.abs(p.y - q.y) >= R.FOOT.h
            end
            -- A is placed and closed; B is dropped on A's spot: A's spot steps beside
            -- the drop, and each window keeps a place of its own
            local three = R.arrange(nil, "com.code", { win(1, 101, "a — A"), win(2, 102, "b — B"), win(3, 103, "c — C") }).json
            three = R.move(three, "com.code", "w101", 0.5, 0.5).json
            -- C sits where the nearest point beside the drop would be
            three = R.move(three, "com.code", "w103", 0.30, 0.45).json
            local drop = R.move(three, "com.code", "w102", 0.52, 0.51)
            local s = {}
            for _, e in ipairs(entries(drop.json, "com.code")) do s[e.wid] = e end
            ok(drop.status == "moved" and s[102].x == 0.52 and s[102].y == 0.51, "a drop stays where it was let go")
            ok(apart(s[101], s[102]) and s[101].placed, "the spot it covered steps beside it, still placed by hand")
            ok(apart(s[101], s[103]), "clear of every other spot too")
            ok(math.abs(s[101].x - 0.5) < 0.3 and math.abs(s[101].y - 0.5) < 0.3, "right beside it, not across the room")
            ok(s[103].x == 0.30 and s[103].y == 0.45, "a spot the drop does not cover stays where it was")
            ok(#drop.nudged == 1 and drop.nudged[1] == "w101", "the move names the spot it moved")
            local both = R.arrange(drop.json, "com.code", { win(1, 101, "a — A"), win(2, 102, "b — B") })
            ok(not spotOf(both, 101).aside and not spotOf(both, 102).aside
                and spotOf(both, 101).x == s[101].x and spotOf(both, 102).x == 0.52,
                "both open: each is drawn at its own spot")

            -- A and B both placed by hand on one spot (a drop that found no clear point
            -- to move the other to); B was seen there last; A comes back
            local raw = json.encode(json.asObject({ v = 2, apps = json.asObject({ ["com.code"] = json.asArray({
                json.asObject({ wid = 102, title = "b — B", x = 0.5, y = 0.5, placed = true }),
                json.asObject({ wid = 101, title = "a — A", x = 0.5, y = 0.5, placed = true }),
            }) }) }))
            local back = R.arrange(raw, "com.code", { win(1, 101, "a — A"), win(2, 102, "b — B") })
            local a, b = spotOf(back, 101), spotOf(back, 102)
            ok(b.x == 0.5 and b.y == 0.5 and not b.aside,
                "both placed by hand: the window seen there last (B) keeps the spot")
            ok(a.aside and apart(a, b), "the one coming back is drawn beside it, not on it")
            ok(math.abs(a.x - 0.5) < 0.3 and math.abs(a.y - 0.5) < 0.3, "right beside it, not across the room")
            ok(a.entry.x == 0.5 and a.entry.y == 0.5, "and its own spot is still remembered")
            local alone = R.arrange(back.json, "com.code", { win(1, 101, "a — A") })
            ok(spotOf(alone, 101).x == 0.5 and not spotOf(alone, 101).aside, "once the spot is free, it is drawn there again")

            -- a hand-placed spot beats an automatic one, even one seen more recently
            local contested = json.encode(json.asObject({ v = 2, apps = json.asObject({ ["com.code"] = json.asArray({
                json.asObject({ wid = 202, title = "auto", x = 0.5, y = 0.5 }),
                json.asObject({ wid = 201, title = "mine", x = 0.5, y = 0.5, placed = true }),
            }) }) }))
            local both = R.arrange(contested, "com.code", { win(1, 201, "mine"), win(2, 202, "auto") })
            ok(spotOf(both, 201).x == 0.5 and not spotOf(both, 201).aside and spotOf(both, 202).aside,
                "a spot placed by hand beats an automatic one on it")
            local stored = {}
            for _, e in ipairs(entries(both.json, "com.code")) do stored[e.wid] = e end
            ok(stored[202].x == 0.5 and stored[202].y == 0.5, "standing aside changes nothing stored")

            -- more open windows than slots: none drawn on another while the picture has room
            local live = {}
            for i = 1, #R.SLOTS + 3 do live[i] = win(i, 8000 + i, "c" .. i) end
            local crowd = R.arrange(nil, "com.code", live)
            local clash = false
            for i = 1, #crowd.spots do
                for j = i + 1, #crowd.spots do
                    if not apart(crowd.spots[i], crowd.spots[j]) then clash = true end
                end
            end
            ok(not clash, "a crowded room still draws every open window clear of the others")

            -- two windows dropped side by side (the panel lands a drop R.FOOT clear of
            -- the others) stay put, whichever of them was seen last
            local pair = R.arrange(nil, "com.code", { win(1, 401, "l"), win(2, 402, "r") }).json
            pair = R.move(pair, "com.code", "w401", 0.40, 0.5).json
            pair = R.move(pair, "com.code", "w402", 0.40 + R.FOOT.w + 0.001, 0.5).json
            local steady = true
            for _, first in ipairs({ 1, 2, 1 }) do
                local rows = { win(1, 401, "l"), win(2, 402, "r") }
                local o = R.arrange(pair, "com.code", { rows[first], rows[3 - first] })
                for _, sp in ipairs(o.spots) do if sp.aside then steady = false end end
                pair = o.json
            end
            ok(steady, "two windows a footprint apart are never drawn aside, whichever was seen last")
        end

        -- ===== a remembered wid counts only for the process it was seen in =====
        do
            local function pwin(id, wid, pid, title)
                local w = win(id, wid, title)
                w.pid = pid
                return w
            end
            local raw = R.arrange(nil, "com.code", { pwin(1, 101, 500, "api — Code") }).json
            raw = R.move(raw, "com.code", "w101", 0.2, 0.3).json
            ok(entries(raw, "com.code")[1].pid == 500, "a window's pid is kept with its wid")
            -- after a reboot, a new window of the same app is handed the old wid
            local rebooted = R.arrange(raw, "com.code", { pwin(1, 101, 900, "notes — Code") })
            local sp = rebooted.spots[1]
            ok(sp.new and not (sp.x == 0.2 and sp.y == 0.3),
                "a wid seen under another pid is another window: it gets a spot of its own")
            local kept
            for _, e in ipairs(entries(rebooted.json, "com.code")) do
                if e.title == "api — Code" then kept = e end
            end
            ok(kept and kept.x == 0.2 and kept.placed, "and the window the wid was stored for keeps its spot")
            local same = R.arrange(raw, "com.code", { pwin(1, 101, 500, "api (edited) — Code") })
            ok(not same.spots[1].new and same.spots[1].x == 0.2,
                "under the same pid a wid still finds its window through a retitle")
            local legacy = json.encode(json.asObject({ v = 2, apps = json.asObject({ ["com.code"] = json.asArray({
                json.asObject({ wid = 101, title = "old title", x = 0.2, y = 0.3, placed = true }),
            }) }) }))
            local l = R.arrange(legacy, "com.code", { pwin(1, 101, 900, "new title") })
            ok(not l.spots[1].new and l.spots[1].entry.pid == 900,
                "an entry with no pid on record is found by its wid, and takes the window's pid")
        end

        -- ===== private windows: shown and placed, never stored =====
        do
            local W = require("platform.windows")
            ok(W.isPrivate("Sign in - Google Chrome (Incognito)") and W.isPrivate("x — Mozilla Firefox Private Browsing")
                and W.isPrivate("News - [InPrivate] - Microsoft Edge") and W.isPrivate("anything", "org.torproject.torbrowser"),
                "Incognito, Private Browsing, InPrivate and Tor Browser are private")
            ok(not W.isPrivate("room.lua — hammerdeck", "com.code"), "an ordinary window is not")
            local stored = json.encode(json.asObject({ v = 2, apps = json.asObject({
                ["com.code"] = json.asArray({ json.asObject({ wid = 1, title = "Mail - Google Chrome (Incognito)", x = 0.2, y = 0.2 }),
                                              json.asObject({ wid = 2, title = "ok", x = 0.5, y = 0.5 }) }),
                ["org.torproject.torbrowser"] = json.asArray({ json.asObject({ wid = 3, title = "t", x = 0.5, y = 0.5 }) }),
            }) }))
            local d = R.decode(stored)
            ok(#d.apps["com.code"] == 1 and d.apps["com.code"][1].wid == 2 and d.apps["org.torproject.torbrowser"] == nil,
                "a private window already on disk is dropped, so the next save removes it")

            local P = "Secret page - Google Chrome (Incognito)"
            local a = R.arrange(nil, "com.code", { win(1, 101, "a — A"), win(2, 102, P) })
            local pv
            for _, sp in ipairs(a.spots) do if sp.entry.wid == 102 then pv = sp end end
            ok(pv and pv.entry.isPrivate and pv.x == R.SLOTS[2].x, "a private window is drawn and gets a spot")
            ok(not a.json:find("Secret", 1, true) and not a.json:find("102", 1, true), "nothing of it is stored")
            ok(a.mem["w102"] == pv.entry, "its spot is held in memory")
            a.mem["w102"].x, a.mem["w102"].y, a.mem["w102"].placed = 0.66, 0.33, true    -- the controller's drag
            local b = R.arrange(a.json, "com.code", { win(1, 101, "a — A"), win(2, 102, P), win(3, 103, "c — C") }, a.mem)
            local pv2
            for _, sp in ipairs(b.spots) do if sp.entry.wid == 102 then pv2 = sp end end
            ok(pv2.x == 0.66 and pv2.y == 0.33 and not pv2.new, "the next open finds it where it was dragged, from memory")
            local c = R.arrange(b.json, "com.code", { win(1, 101, "a — A") }, b.mem)
            ok(next(c.mem) == nil, "closed, a private window is forgotten")
        end

        -- ===== move / picture =====
        do
            local a = R.arrange(nil, "com.code", { win(1, 101, "api") })
            local id = R.windowId(a.spots[1].entry)
            ok(id == "w101", "a window goes by its wid")
            local op = R.move(a.json, "com.code", id, 0.9, 0.1)
            local e = entries(op.json, "com.code")[1]
            ok(op.status == "moved" and e.x == 0.9 and e.y == 0.1, "a drag moves the spot")
            local back = R.arrange(op.json, "com.code", { win(1, 101, "api") })
            ok(back.spots[1].entry.x == 0.9, "and the next open draws it where it was dropped")
            ok(R.move(a.json, "com.code", "w999", 0, 0).status == "nowindow", "moving an unknown window is refused")
            ok(#entries(R.setImage(op.json, "neon").json, "com.code") == 1, "a new picture keeps every spot")
        end

        -- ===== the spots the user placed, for the Settings page =====
        do
            local raw = R.arrange(nil, "com.code", { win(1, 101, "api — Code"), win(2, 102, "a-very-long-project-name-here — Code") }).json
            raw = R.arrange(raw, "com.term", { win(3, 301, "zsh", "com.term") }).json
            ok(#R.keptApps(raw) == 0 and #R.kept(raw, "com.code", "Code") == 0,
                "spots the room chose itself are not kept spots")
            raw = R.move(raw, "com.code", "w102", 0.3, 0.4).json
            local apps, kept = R.keptApps(raw), R.kept(raw, "com.code", "Code")
            ok(#apps == 1 and apps[1] == "com.code", "an app is listed once a spot in its room is placed by hand")
            ok(#kept == 1 and kept[1].id == "w102" and kept[1].x == 0.3 and kept[1].y == 0.4
                and kept[1].name == "a-very-l…me-here" and kept[1].title == "a-very-long-project-name-here — Code",
                "a kept spot carries its id, place, and the label the room draws")
            local gone = R.forget(raw, "com.code", "w102")
            ok(gone.status == "forgot" and #entries(gone.json, "com.code") == 1 and #R.keptApps(gone.json) == 0,
                "forgetting a spot drops that window's entry and nothing else")
            ok(R.forget(gone.json, "com.code", "w102").status == "nowindow", "forgetting it twice is refused")
            local last = R.forget(R.forget(gone.json, "com.code", "w101").json, "com.term", "w301")
            ok(last.status == "forgot" and not last.json:find("com.code", 1, true)
                and not last.json:find("com.term", 1, true), "an app with nothing left drops out of the record")
            local back = R.arrange(gone.json, "com.code", { win(2, 102, "a-very-long-project-name-here — Code") })
            ok(back.spots[1].new, "a forgotten window that is still open is new to the room next time")
        end

        -- ===== the live flow =====
        registry.register(require("features.memory_room"))
        registry.setEnabled("memory_room", true)

        fake.windows = {
            win(1, 101, "room.lua — hammerdeck — Code"), win(2, 102, "a-very-long-project-name-here — Code"),
            win(3, 301, "zsh", "com.term"),
        }
        front("Code", "com.code")
        fake.focusedWid = 102
        fake.pressHotkey("l", HYP)
        local room = fake.liveRoomPanel()
        ok(room ~= nil, "the room is drawn at once, to be pointed at")
        ok(room and #room.spec.pins == 2 and room.spec.title == "Code",
            "only the front app's windows, under the app's name")
        ok(room and room.spec.pins[1].name == "hammerdeck"
            and room.spec.pins[1].title == "room.lua — hammerdeck — Code",
            "a window's label is the last part of its title that is not the app (the project, not the "
            .. "file open in it); the full title rides along for hover")
        ok(room and room.spec.pins[2].name == "a-very-l…me-here",
            "a long label keeps both ends, so it stays about one slot wide")
        ok(room and room.spec.front == "w102", "the window in front is marked")
        ok(room and room.spec.pins[1].wid == 101 and room.spec.pins[2].wid == 102,
            "each window carries its wid, so hovering it can show its picture")
        ok(room and room.spec.hint == "click: bring it forward    drag: move it    esc: close", "the hint names clicks")
        ok(room and room.spec.foot and room.spec.foot.w == R.FOOT.w and room.spec.foot.h == R.FOOT.h,
            "the panel is told the footprint a drop must land clear of")

        fake.pickRoom({ id = "w102" })
        ok(fake.focused[#fake.focused] == 2, "a click focuses the window it names (its listed id)")
        ok(fake.liveRoomPanel() == nil, "and closes the room")

        fake.pressHotkey("l", HYP)
        fake.pickRoom({ id = "w101", action = "move", x = 0.8, y = 0.2 })
        local moved
        for _, x in ipairs(entries(fake.settings[STATE], "com.code")) do if x.wid == 101 then moved = x end end
        ok(moved and moved.x == 0.8 and moved.y == 0.2, "a drag keeps the new spot")
        ok(fake.liveRoomPanel() ~= nil, "and the room stays open")
        fake.pickRoom(nil)
        ok(fake.liveRoomPanel() == nil, "a click off every window closes the room")

        fake.pressHotkey("l", HYP)
        local before = #fake.focused
        fake.pressHotkey("escape", {})
        ok(fake.liveRoomPanel() == nil and #fake.focused == before, "Escape closes the room and focuses nothing")
        fake.settings[STATE] = nil

        -- a private window in the live room: drawn, dragged, never written down
        fake.windows[#fake.windows + 1] = win(4, 104, "Secret page - Google Chrome (Incognito)")
        fake.logs = {}
        fake.pressHotkey("l", HYP)
        local drawn
        for _, pin in ipairs(fake.liveRoomPanel().spec.pins) do if pin.wid == 104 then drawn = pin end end
        ok(drawn ~= nil, "a private window is in the room")
        fake.pickRoom({ id = "w104", action = "move", x = 0.66, y = 0.33 })
        fake.pickRoom(nil)
        fake.pressHotkey("l", HYP)
        for _, pin in ipairs(fake.liveRoomPanel().spec.pins) do if pin.wid == 104 then drawn = pin end end
        ok(drawn.x == 0.66 and drawn.y == 0.33, "dragged, it stays where it was put while Hammerdeck runs")
        ok(not fake.settings[STATE]:find("Secret", 1, true), "its title never reaches the stored record")
        local leaked = false
        for _, line in ipairs(fake.logs) do if line:find("Secret", 1, true) then leaked = true end end
        ok(not leaked, "nor the log")
        fake.pickRoom(nil)
        table.remove(fake.windows)

        -- the three empty cases, each with its own way out
        front("Notes", "com.notes")
        fake.pressHotkey("l", HYP)
        ok(fake.alerts[#fake.alerts] == "Notes has no open windows.", "an app with no windows says so")
        fake.droppedApps = { "com.notes" }
        fake.pressHotkey("l", HYP)
        ok(fake.alerts[#fake.alerts] == "Notes did not answer in time. Try again.",
            "an app that did not answer is not mistaken for one with no windows")
        fake.droppedApps = {}
        local saved = fake.windows
        fake.windows, fake.axTrusted = {}, false
        local prompts = fake.axPrompts
        fake.pressHotkey("l", HYP)
        ok(fake.alerts[#fake.alerts] == "Memory Room needs Accessibility to see your windows."
            and fake.axPrompts == prompts + 1, "no Accessibility: says so and asks for it")
        fake.windows, fake.axTrusted = saved, true
        front("", "")
        fake.pressHotkey("l", HYP)
        ok(fake.alerts[#fake.alerts] == "No app is in front.", "no app in front")

        -- disabling mid-room tears everything down
        front("Code", "com.code")
        fake.pressHotkey("l", HYP)
        ok(fake.liveRoomPanel() ~= nil, "room drawn before the disable")
        registry.setEnabled("memory_room", false)
        ok(fake.liveRoomPanel() == nil, "disabling closes the room")
        fake.focusedWid = nil
    end,
}
