-- test/cases/memory_room.lua -- memory_room: a memory palace for apps. Two halves:
--
-- 1. room.lua, the pure schema both writers share (the running feature and the
--    Settings page via readerCall): the default room, decode's forgiveness rules,
--    key-from-position, and every edit -- above all place(), whose "an app lives
--    in ONE place" and "a full place refuses WITHOUT unplacing" rules are the
--    ones a regression would break silently.
-- 2. The live flow over the fake: Hyper+L arms a silent modal. With letters
--    drawn, the room appears only after the pause, a letter brings an app forward
--    (stepping on a repeat press), Shift+letter places the frontmost app -- with
--    Hyper still held too. Without them (the default), the room appears at once
--    and is clicked: a place, one of its icons, the right-click item, or off
--    every place to close -- and the unseen letters still work.
--
-- Hermetic: registers memory_room itself; state lives in fake.settings.

local STATE = "hammerdeck.state.memory_room.room"

return {
    id = "memory_room",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry
        local HYP = { "cmd", "alt", "ctrl" }
        local R = require("features.memory_room.room")
        local function front(name, bundleId) fake.frontmost, fake.frontmostId = name, bundleId end

        -- ===== the default room =====
        do
            local room = R.decode(nil)
            ok(room.image == nil, "no stored record: the default room (no photo)")
            ok(#room.pins == 9, "the default room has its nine places")
            local seen, valid = {}, true
            for _, p in ipairs(room.pins) do
                local onRow = false
                for _, row in ipairs(R.ROWS) do if row:find(p.key, 1, true) then onRow = true end end
                if seen[p.key] or not onRow or p.x < 0 or p.x > 1 or p.y < 0 or p.y > 1 then valid = false end
                seen[p.key] = true
            end
            ok(valid, "default keys are unique, on the three letter rows, and inside the image")
            ok(R.pinByKey(room, "d").nameKey == "desk", "D is the desk")
            ok(#R.decode("not json").pins == 9, "an unreadable record falls back to the default room")
            ok(#R.decode('{"v":1,"pins":[]}').pins == 0,
                "a record with every pin removed stays EMPTY (the default is not resurrected)")
        end

        -- ===== decode forgives one bad pin at a time =====
        do
            local room = R.decode([[{"v":1,"image":"room.jpg","pins":[
                {"id":"p1","key":"d","x":0.3,"y":0.5,"apps":["a","a","b"]},
                {"id":"p2","key":"d","x":0.1,"y":0.1,"apps":[]},
                {"id":"p3","key":"1","x":0.1,"y":0.1,"apps":[]},
                {"id":"p4","key":"K","x":2,"y":-1,"apps":["b","c"]}]}]])
            ok(room.image == "room.jpg", "the custom photo survives decode")
            ok(#room.pins == 2, "a duplicate key and a key off the letter rows are dropped")
            ok(#room.pins[1].apps == 2, "a repeated app on one pin collapses to one")
            ok(room.pins[2].key == "k", "keys are lower-cased")
            ok(room.pins[2].x == 1 and room.pins[2].y == 0, "coordinates are clamped into the image")
            ok(#room.pins[2].apps == 1 and room.pins[2].apps[1] == "c",
                "an app already placed on an earlier pin stays only there")
        end

        -- ===== key from position =====
        do
            local empty = '{"v":1,"pins":[]}'
            local op = R.addPin(empty, 0.25, 0.1, "Shelf")
            ok(op.status == "added" and R.decode(op.json).pins[1].key == "e",
                "top third, third column: E")
            op = R.addPin(op.json, 0.25, 0.1, "")
            ok(R.decode(op.json).pins[2].key == "w", "E taken: the nearest free letter, left first")
            op = R.addPin(op.json, 0.99, 0.99, "")
            ok(R.decode(op.json).pins[3].key == "/", "bottom-right corner: /")
            local id = R.decode(op.json).pins[1].id
            local moved = R.movePin(op.json, id, 0.9, 0.9)
            ok(R.decode(moved.json).pins[1].key == "e", "moving a pin never changes its learned key")
            local full = empty
            for i = 1, R.MAX_PINS do full = R.addPin(full, (i % 10) / 10, 0.5, "").json end
            ok(#R.decode(full).pins == R.MAX_PINS, "all thirty letters can be used")
            ok(R.addPin(full, 0.5, 0.5, "").status == "full", "a thirty-first pin is refused")
        end

        -- ===== edits =====
        do
            local raw = R.encode(R.decode(nil))
            local desk = R.pinByKey(R.decode(raw), "d")
            local op = R.setKey(raw, desk.id, "k")
            local room = R.decode(op.json)
            ok(op.status == "swapped" and R.pinByKey(room, "k").id == desk.id
                and R.pinByKey(room, "d").nameKey == "armchair",
                "taking a used key swaps it: no edit can put two places on one letter")
            ok(R.setKey(raw, desk.id, "1").status == "badkey", "a key off the letter rows is refused")
            op = R.renamePin(raw, desk.id, "Work")
            room = R.decode(op.json)
            ok(R.pinByKey(room, "d").name == "Work" and R.pinByKey(room, "d").nameKey == nil,
                "renaming drops the default name so the user's name shows")
            op = R.removePin(raw, desk.id)
            ok(#R.decode(op.json).pins == 8 and R.pinByKey(R.decode(op.json), "d") == nil, "remove a pin")
            op = R.setImage(raw, "room.png")
            ok(R.decode(op.json).image == "room.png" and #R.decode(op.json).pins == 9,
                "a new photo keeps the pins")
            ok(R.decode(R.setImage(op.json, "").json).image == nil, "\"\" returns to the default room")
            ok(R.decode(raw).showKeys == false, "letters are hidden by default")
            ok(not raw:find("showKeys", 1, true),
                "a record that never showed letters is written without the field")
            op = R.setShowKeys(raw, true)
            ok(op.status == "showKeys" and R.decode(op.json).showKeys == true
                and #R.decode(op.json).pins == 9, "show letters, keeping every place")
            ok(R.decode(R.place(op.json, "d", "x").json).showKeys == true, "every other edit keeps it")
            ok(R.decode(R.setShowKeys(op.json, false).json).showKeys == false, "and hide them again")
        end

        -- ===== place: one app, one place =====
        do
            local raw = R.encode(R.decode(nil))
            local op = R.place(raw, "d", "slack")
            ok(op.status == "placed", "place an app")
            ok(R.place(op.json, "d", "slack").status == "already", "placing it there again is a no-op")
            op = R.place(op.json, "k", "slack")
            local room = R.decode(op.json)
            ok(op.status == "moved" and #R.pinByKey(room, "d").apps == 0
                and R.pinByKey(room, "k").apps[1] == "slack", "placing elsewhere MOVES the app")
            raw = op.json
            for _, a in ipairs({ "a", "b", "c" }) do raw = R.place(raw, "d", a).json end
            op = R.place(raw, "d", "slack")
            room = R.decode(op.json)
            ok(op.status == "full" and R.pinByKey(room, "k").apps[1] == "slack",
                "a full place refuses AND leaves the app where it was")
            ok(R.place(raw, "q", "x").status == "nopin", "a key with no place")
            ok(R.place(raw, "d", "").status == "noapp", "no frontmost app")
            local pin = assert(R.pinByKey(R.decode(raw), "d"))
            ok(R.nextIndex(pin, "zzz") == 1, "nothing of the place in front: the first app")
            ok(R.nextIndex(pin, "a") == 2 and R.nextIndex(pin, "c") == 1,
                "the app in front steps to the next one, wrapping")
            op = R.unplace(raw, pin.id, "b")
            ok(op.status == "unplaced" and #R.pinByKey(R.decode(op.json), "d").apps == 2, "unplace")
        end

        -- ===== placeAt: an app goes wherever it is put =====
        do
            local empty = '{"v":1,"pins":[]}'
            local op = R.placeAt(empty, 0.25, 0.1, "slack")
            local room = R.decode(op.json)
            ok(op.status == "placed" and #room.pins == 1 and room.pins[1].key == "e"
                and room.pins[1].name == "" and room.pins[1].apps[1] == "slack"
                and room.pins[1].x == 0.25 and room.pins[1].y == 0.1,
                "a new unnamed place right there, on the letter under that spot")
            local first = room.pins[1].id
            op = R.placeAt(op.json, 0.9, 0.9, "slack")
            room = R.decode(op.json)
            ok(op.status == "moved" and op.from == first and #room.pins == 1 and room.pins[1].id ~= first
                and room.pins[1].apps[1] == "slack",
                "put elsewhere, it moves -- and the unnamed place it left goes with it")
            ok(R.decode(R.placeAt(op.json, 0.5, 0.5, "x").json).pins[2].key ~= room.pins[1].key,
                "a new place never takes a letter already in use")
            op = R.place(R.placeAt(R.encode(R.decode(nil)), 0.5, 0.5, "slack").json, "d", "slack")
            room = R.decode(op.json)
            ok(op.status == "moved" and #room.pins == 9, "moving into a named place also drops the unnamed one")
            op = R.place(op.json, "k", "slack")
            room = R.decode(op.json)
            ok(#room.pins == 9 and #R.pinByKey(room, "d").apps == 0,
                "a NAMED place stays when its last app leaves")
            local full = empty
            for i = 1, R.MAX_PINS do full = R.addPin(full, (i % 10) / 10, 0.5, "").json end
            op = R.placeAt(full, 0.5, 0.5, "slack")
            ok(op.status == "full" and op.json == R.encode(R.decode(full)), "every letter used: refused, nothing changes")
            local lone = R.placeAt(R.addPin(full, 0, 0, "").json, 0.1, 0.1, "slack")
            ok(lone.status == "full", "(the thirty-first place is refused before any app moves)")
            local moved = R.placeAt(R.place(full, R.decode(full).pins[1].key, "slack").json, 0.5, 0.5, "slack")
            ok(moved.status == "moved", "full, but the app's own unnamed place frees a letter for the new spot")
            ok(R.placeAt(empty, 0.5, 0.5, "").status == "noapp", "no app in front")
        end

        -- ===== the live flow, letters drawn =====
        registry.register(require("features.memory_room"))
        registry.setEnabled("memory_room", true)

        fake.settings[STATE] = R.setShowKeys(nil, true).json
        fake.pressHotkey("l", HYP)
        ok(fake.liveRoomPanel() == nil, "Hyper+L draws nothing yet (no flash on a fast jump)")
        ok(#fake.banners == 0 and #fake.huds == 0, "the room's modal is silent")
        fake.fireTimers("after", 0.35)
        local panel = fake.liveRoomPanel()
        ok(panel ~= nil and #panel.spec.pins == 9, "after the pause the room is drawn")
        ok(panel.spec.image == nil, "the default room carries no photo name")

        -- an empty place: say how to fill it, stay open
        fake.pressHotkey("d", {})
        ok(fake.alerts[#fake.alerts] == "Desk is empty. Shift+D puts the app in front there.",
            "an empty place explains how to fill it")
        ok(fake.liveRoomPanel() ~= nil, "and the room stays open")

        -- place the frontmost app, with Shift alone
        front("Slack", "com.tinyspeck.slackmacgap")
        fake.pressHotkey("d", { "shift" })
        ok(fake.alerts[#fake.alerts] == "Slack → Desk", "Shift+D puts the app in front on the desk")
        ok(fake.liveRoomPanel() == nil, "placing closes the room")
        ok(R.pinByKey(R.decode(fake.settings[STATE]), "d").apps[1] == "com.tinyspeck.slackmacgap",
            "the place is persisted")

        -- place a second app with Hyper STILL HELD (the explicit leader+shift twin)
        front("Terminal", "com.apple.Terminal")
        fake.pressHotkey("l", HYP)
        fake.pressHotkey("d", { "cmd", "alt", "ctrl", "shift" })
        ok(fake.alerts[#fake.alerts] == "Terminal → Desk", "Hyper+Shift+D places with the leader held")

        -- jump: the app after the one in front, in placement order
        front("Terminal", "com.apple.Terminal")
        fake.pressHotkey("l", HYP)
        fake.pressHotkey("d", {})
        ok(fake.launchedApps[#fake.launchedApps] == "com.tinyspeck.slackmacgap",
            "Terminal in front: D steps on to Slack (wrapping)")
        ok(fake.liveRoomPanel() == nil, "jumping closes the room before it was ever drawn")
        front("Slack", "com.tinyspeck.slackmacgap")
        fake.pressHotkey("l", HYP)
        fake.pressHotkey("d", HYP)
        ok(fake.launchedApps[#fake.launchedApps] == "com.apple.Terminal",
            "Slack in front: Hyper+L D (leader held) steps on to Terminal")

        -- an app uninstalled since it was placed: skipped, not stopped on
        fake.uninstalledApps["com.apple.Terminal"] = true
        front("Slack", "com.tinyspeck.slackmacgap")
        local alertsBefore = #fake.alerts
        fake.pressHotkey("l", HYP)
        fake.pressHotkey("d", {})
        ok(fake.launchedApps[#fake.launchedApps] == "com.tinyspeck.slackmacgap"
            and #fake.alerts == alertsBefore,
            "the next app is gone: the step wraps on to the one that still exists, silently")
        -- every app in the place gone: say where to fix it
        fake.uninstalledApps["com.tinyspeck.slackmacgap"] = true
        fake.pressHotkey("l", HYP)
        fake.pressHotkey("d", {})
        ok(fake.alerts[#fake.alerts]
            == "The app on Desk is no longer installed. Remove it in Settings > Memory Room.",
            "a place whose apps are all gone says where to remove them")
        fake.uninstalledApps["com.apple.Terminal"] = nil
        fake.uninstalledApps["com.tinyspeck.slackmacgap"] = nil

        -- Hyper still held after a jump: the room stays open, D again steps on
        -- (from the last jump -- the fake's front app never catches up, like a slow
        -- activation), and releasing Hyper closes it
        fake.settings[STATE] = R.place(R.place(nil, "d", "com.a").json, "d", "com.b").json
        front("Finder", "com.apple.finder")
        fake.modifiers = { cmd = true, alt = true, ctrl = true }
        fake.pressHotkey("l", HYP)
        fake.pressHotkey("d", HYP)
        ok(fake.launchedApps[#fake.launchedApps] == "com.a", "held: D brings the first app forward")
        fake.pressHotkey("d", HYP)
        ok(fake.launchedApps[#fake.launchedApps] == "com.b",
            "held: D again steps on, though the front app has not caught up")
        fake.pressHotkey("d", HYP)
        ok(fake.launchedApps[#fake.launchedApps] == "com.a", "held: and wraps round the place")
        local launched = #fake.launchedApps
        fake.modifiers = {}
        fake.fireTimers("every", 0.05)
        fake.pressHotkey("d", HYP)
        fake.pressHotkey("d", {})
        ok(#fake.launchedApps == launched, "released: the room closes, and D is a plain key again")
        fake.settings[STATE] = nil

        -- a place whose first app was uninstalled still reaches the ones after it
        fake.settings[STATE] = R.place(R.place(nil, "d", "com.gone").json, "d", "com.apple.Notes").json
        fake.uninstalledApps["com.gone"] = true
        front("Finder", "com.apple.finder")
        fake.pressHotkey("l", HYP)
        fake.pressHotkey("d", {})
        ok(fake.launchedApps[#fake.launchedApps] == "com.apple.Notes",
            "an uninstalled app does not block stepping on to the next one")
        fake.uninstalledApps["com.gone"] = nil
        fake.settings[STATE] = nil

        -- a leader that already has Shift: the place twin would duplicate the bare
        -- key's leader twin, which the real seam refuses -- so it is not bound
        fake.rejectHotkey = function(mods, key, shadow)
            local want = {}
            for _, m in ipairs(mods) do want[m] = true end
            for _, h in ipairs(fake.hotkeys) do
                if not h.stopped and not h.parked and not shadow and h.key == key and #h.mods == #mods then
                    local same = true
                    for _, m in ipairs(h.mods) do if not want[m] then same = false end end
                    if same then return true end
                end
            end
            return false
        end
        registry.setTrigger("memory_room", "open", { type = "hotkey", mods = { "cmd", "shift" }, key = "l" })
        local before = #fake.alerts
        fake.pressHotkey("l", { "cmd", "shift" })
        fake.pressHotkey("d", { "shift" })
        ok(#fake.alerts == before + 1 and fake.alerts[#fake.alerts] == "Finder → Desk",
            "a Shift leader still opens the room and places (no duplicate registration)")
        fake.rejectHotkey = nil
        registry.clearTrigger("memory_room", "open")
        fake.settings[STATE] = nil

        -- ===== the click flow, letters hidden (the default) =====
        fake.settings[STATE] = R.place(R.place(nil, "k", "com.a").json, "k", "com.b").json
        front("Finder", "com.apple.finder")
        fake.pressHotkey("l", HYP)
        local room = fake.liveRoomPanel()
        ok(room ~= nil and room.spec.showKeys == false,
            "no letters: the room is drawn at once, to be clicked, and told not to draw them")
        ok(room and room.spec.hint
            == "click: bring it forward    right-click anywhere: put the app you're in there    esc: close",
            "the hint line names clicks, not letters")
        ok(room and #room.spec.pins == 1 and room.spec.pins[1].key == "k",
            "a clicked room draws only the places that hold apps")
        ok(room and room.spec.placeLabel == "Put Finder here", "the right-click item names the app in front")
        fake.pickRoom({ key = "k" })
        ok(fake.launchedApps[#fake.launchedApps] == "com.a", "a click on a place brings its app forward")
        ok(fake.liveRoomPanel() == nil, "and closes the room")

        fake.pressHotkey("l", HYP)
        fake.pickRoom({ key = "k", app = 2 })
        ok(fake.launchedApps[#fake.launchedApps] == "com.b", "a click on an icon brings THAT app forward")

        fake.pressHotkey("l", HYP)
        fake.pressHotkey("d", {})
        ok(fake.alerts[#fake.alerts] == "Desk is empty. Shift+D puts the app in front there.",
            "an undrawn empty place, reached by its hidden letter, says how to fill it by letter")
        ok(fake.liveRoomPanel() ~= nil, "and the room stays open")
        fake.pickRoom({ action = "placeAt", x = 0.5, y = 0.3 })
        ok(fake.alerts[#fake.alerts] == "Finder is in the room",
            "right-click off every place puts the app in front right there, naming no unseen letter")
        ok(fake.liveRoomPanel() == nil, "placing closes the room")
        local placed = R.decode(fake.settings[STATE])
        local here
        for _, p in ipairs(placed.pins) do if p.apps[1] == "com.apple.finder" then here = p end end
        ok(here and here.x == 0.5 and here.y == 0.3 and #placed.pins == 10, "a new place, where the click was")

        fake.pressHotkey("l", HYP)
        ok(#fake.liveRoomPanel().spec.pins == 2, "and the room now draws it")
        fake.pickRoom({ key = here.key, action = "place" })
        ok(fake.alerts[#fake.alerts] == "Finder is already there", "right-click on its own place: already there")

        fake.pressHotkey("l", HYP)
        fake.pickRoom({ key = "k", action = "place" })
        ok(fake.alerts[#fake.alerts] == "Finder → Armchair", "right-click on a named place joins it")
        ok(#R.decode(fake.settings[STATE]).pins == 9, "and the unnamed place Finder left is gone")

        local launchedBefore = #fake.launchedApps
        fake.pressHotkey("l", HYP)
        fake.pickRoom(nil)
        ok(fake.liveRoomPanel() == nil, "a click off every place closes the room")
        fake.pressHotkey("k", {})
        ok(#fake.launchedApps == launchedBefore, "and releases its letters with it")

        fake.pressHotkey("l", HYP)
        fake.pressHotkey("k", {})
        ok(#fake.launchedApps == launchedBefore + 1, "hidden letters still work")

        front("", "")
        fake.pressHotkey("l", HYP)
        ok(fake.liveRoomPanel().spec.placeLabel == nil, "no app in front: the menu offers nothing to put")
        fake.pickRoom(nil)
        fake.settings[STATE] = nil

        -- every default place's name has a literal ctx.t key in init.lua (the
        -- Settings page reads the same keys, and only i18n_parity checks them)
        do
            local f = assert(io.open("app/features/memory_room/lua/init.lua"))
            local src = f:read("a"); f:close()
            local missing = {}
            for _, p in ipairs(R.default().pins) do
                if not src:find('ctx.t("memoryRoom.pin.' .. p.nameKey .. '"', 1, true) then
                    missing[#missing + 1] = p.nameKey
                end
            end
            ok(#missing == 0, "every default place name is localized: missing " .. table.concat(missing, ","))
        end

        -- a room with no places: lettered, it points at Settings instead of arming
        -- a modal with no keys; clicked, it opens, since a right-click fills it
        fake.settings[STATE] = '{"v":1,"showKeys":true,"pins":[]}'
        fake.pressHotkey("l", HYP)
        ok(fake.alerts[#fake.alerts] == "This room has no places yet. Add some in Settings > Memory Room.",
            "an empty lettered room points at Settings")
        fake.settings[STATE] = '{"v":1,"pins":[]}'
        front("Finder", "com.apple.finder")
        fake.pressHotkey("l", HYP)
        ok(fake.liveRoomPanel() ~= nil and #fake.liveRoomPanel().spec.pins == 0,
            "an empty clicked room opens, ready for a right-click")
        fake.pickRoom({ action = "placeAt", x = 0.2, y = 0.2 })
        ok(#R.decode(fake.settings[STATE]).pins == 1, "and the right-click makes its first place")

        -- disabling mid-room tears everything down
        fake.settings[STATE] = nil
        fake.pressHotkey("l", HYP)
        fake.fireTimers("after", 0.35)
        ok(fake.liveRoomPanel() ~= nil, "room drawn before the disable")
        registry.setEnabled("memory_room", false)
        ok(fake.liveRoomPanel() == nil, "disabling closes the room")
    end,
}
