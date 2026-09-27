-- features/memory_room
--
-- A memory palace for apps. The room is a picture -- an illustrated room, or a
-- photo of a room you know -- with places pinned on it. You put an app in a
-- place once; after that you find it by WHERE it lives, not by reading names.
--
-- By default the room is CLICKED: Hyper+L draws it at once, a click on a place
-- brings its app forward (a click on one of its icons, that app), a right-click
-- puts the app you are in there, and a click anywhere else closes it.
--
-- Every place also sits on the key letter where it is on the keyboard (the
-- picture's top third is the QWERT row, and so on). Those letters always work;
-- the room DRAWS them only when the user turns them on (the record's showKeys):
--
--   Hyper+L, D         bring forward the app on the desk (launch it if needed)
--   ...D again         with Hyper still held: the next app on the desk, in the
--                      order you put them there (the room stays open until
--                      Hyper is released; otherwise Hyper+L, D again)
--   Hyper+L, Shift+D   put the app in front on the desk
--
-- With letters drawn, the room appears only if you pause, so a fast Hyper+L D
-- never flashes a card. Pins are made on the Settings page
-- (swift/MemoryRoomView.swift); the record they live in is owned by room.lua,
-- which the page calls too.
--
-- v1 places hold APPS: an app's identity survives a relaunch, so a place is
-- always resolvable. Windows are a later phase.

local json = require("platform.json")
local hotkeys = require("platform.hotkeys")
local R = require("features.memory_room.room")

-- The pause before a room WITH LETTERS is drawn: long enough that a practiced
-- Hyper+L D never shows it, short enough that hesitating does (ChordCenter's hint
-- delay). A room without letters is there to be clicked, so it is drawn at once.
local SHOW_DELAY = 0.35
-- How often a held room checks whether the entry modifier is still down.
local RELEASE_POLL = 0.05

-- The default room's place names. Global-catalog keys, because the Settings
-- page (Swift, Strings.t) shows the same names from the same catalog.
---@param ctx Ctx
---@return table<string, string>
local function defaultNames(ctx)
    return {
        bookshelf = ctx.t("memoryRoom.pin.bookshelf", "Bookshelf"),
        picture   = ctx.t("memoryRoom.pin.picture", "Picture"),
        window    = ctx.t("memoryRoom.pin.window", "Window"),
        clock     = ctx.t("memoryRoom.pin.clock", "Clock"),
        desk      = ctx.t("memoryRoom.pin.desk", "Desk"),
        armchair  = ctx.t("memoryRoom.pin.armchair", "Armchair"),
        door      = ctx.t("memoryRoom.pin.door", "Door"),
        plant     = ctx.t("memoryRoom.pin.plant", "Plant"),
        table     = ctx.t("memoryRoom.pin.table", "Coffee table"),
    }
end

-- A place's name, nil when it has none (a place the room made for an app).
---@param ctx Ctx
---@param pin RoomPin
---@return string|nil
local function namedAs(ctx, pin)
    local named = pin.nameKey and defaultNames(ctx)[pin.nameKey]
    if named then return named end
    if pin.name ~= "" then return pin.name end
    return nil
end

-- What to call a place in a message: its name, or its key when it has none.
---@param ctx Ctx
---@param pin RoomPin
---@return string
local function placeName(ctx, pin)
    return namedAs(ctx, pin) or pin.key:upper()
end

-- What to call a place in a message the user sees right after using the room:
-- its letter only if the room draws letters -- a letter they never saw names
-- nothing. nil means say it without naming the place.
---@param ctx Ctx
---@param room Room
---@param pin RoomPin
---@return string|nil
local function shownName(ctx, room, pin)
    if room.showKeys then return placeName(ctx, pin) end
    return namedAs(ctx, pin)
end

---@param ctx Ctx
---@param room Room
---@return table
local function panelSpec(ctx, room)
    -- A clicked room draws only places that hold apps: an empty one is nothing
    -- to click, and apps are put anywhere by right-click, not into slots. With
    -- letters drawn, an empty place is still a letter to press.
    local pins = {}
    for _, p in ipairs(room.pins) do
        if room.showKeys or #p.apps > 0 then
            local apps = {}
            for i, a in ipairs(p.apps) do apps[i] = a end
            pins[#pins + 1] = json.asObject({ key = p.key, name = placeName(ctx, p),
                                              x = p.x, y = p.y, apps = json.asArray(apps) })
        end
    end
    local front = ctx.frontmostAppInfo()
    local hint = room.showKeys
        and ctx.t("panel.hint",
            "letter: bring it forward    again: next app    shift+letter: put the front app here    esc: close")
        or ctx.t("panel.clickHint",
            "click: bring it forward    right-click anywhere: put the app you're in there    esc: close")
    return json.asObject({
        title    = ctx.t("panel.title", "Memory Room"),
        image    = room.image,
        pins     = json.asArray(pins),
        front    = front.bundleId,
        showKeys = room.showKeys,
        hint     = hint,
        -- The right-click menu's one item. None when no app is in front: there
        -- is nothing to put anywhere, so the menu does not offer it.
        placeLabel = front.name ~= "" and ctx.t("panel.putHere", "Put %s here", front.name) or nil,
    })
end

---@param ctx Ctx
local function controllerFor(ctx)
    local st = {}

    local function close()
        if st.modal then st.modal.stop() end        -- onExit clears the rest
    end

    local onPick                                    -- defined after jump/place
    local function showPanel(room)
        if st.panel or not st.modal then return end
        st.panel = ctx.roomPanel(panelSpec(ctx, room), function(pick) onPick(pick) end)
    end

    -- After a jump: while the entry hotkey's modifier is still held, the room
    -- stays open, so a held Caps + L, D, D steps through the desk's apps. Closing
    -- at once would hand the second D to whatever global shortcut owns Hyper+D
    -- (Insert Date typing into the app just brought forward). Released -- or
    -- opened with nothing held, from the menubar -- it closes at once, so a held
    -- room never captures typing: letters pressed with Hyper down are not text.
    local function closeOrHold()
        local mod = st.leader
        if not (mod and ctx.isModifierHeld(mod)) then close(); return end
        -- The front app just changed under the drawn room; drop it rather than
        -- leave its "you are here" ring on the wrong place.
        if st.showTimer then st.showTimer.stop(); st.showTimer = nil end
        if st.panel then st.panel.stop(); st.panel = nil end
        if st.releasePoll then return end
        ctx.log("hold: open until", mod, "is released")
        st.releasePoll = ctx.everySeconds(RELEASE_POLL, function()
            if not ctx.isModifierHeld(mod) then
                ctx.log("hold released")
                close()
            end
        end)
    end

    -- Bring forward the app in the place on `key`. `clicked`: it came from the
    -- room, not a letter; `app`: the icon clicked, an index into the place's apps.
    local function jump(key, clicked, app)
        local room = R.decode(ctx.getState("room"))
        local pin = R.pinByKey(room, key)
        if not pin then close(); return end
        local label = placeName(ctx, pin)
        -- A clicked icon names its app. Otherwise a repeat press in the SAME open
        -- room steps on from the last jump: the app it brought forward may not be
        -- frontmost yet (activation is async), and stepping off the stale front
        -- app would land on the same one twice.
        local i
        if app and pin.apps[app] then
            i = app
        elseif #pin.apps > 0 and st.lastJump and st.lastJump.key == key then
            i = st.lastJump.index % #pin.apps + 1
        else
            i = R.nextIndex(pin, ctx.frontmostAppInfo().bundleId)
        end
        if not i then
            -- Nothing here yet: say how to fill it, and keep the room open (and
            -- drawn) so the user can pick another place without starting over.
            -- Only a letter reaches an empty place (a clicked room draws none),
            -- so the letter is the way to fill it.
            ctx.log("jump empty", key)
            ctx.alert(ctx.t("alert.empty", "%1$s is empty. Shift+%2$s puts the app in front there.",
                label, key:upper()))
            showPanel(room)
            return
        end
        -- Try the apps round the place from `i`. One uninstalled since it was
        -- placed keeps its spot (the user decides when to forget it) but must not
        -- block the apps after it: stepping keys off the app in FRONT, and a
        -- missing app never is, so without this every press would stop on it.
        -- A clicked icon is the one app wanted: it is tried alone.
        local n = #pin.apps
        for step = 0, (app and pin.apps[app]) and 0 or n - 1 do
            local k = (i - 1 + step) % n + 1
            local bundleId = pin.apps[k]
            local found = ctx.launchOrFocusApp(bundleId, function(ok, reason)
                if not ok then
                    ctx.log("jump refused", key, bundleId, reason)
                    ctx.alert(ctx.t("alert.launchRefused", "Could not open the app on %1$s: %2$s",
                        label, reason or ""))
                end
            end)
            if found then
                ctx.log("jump", key, bundleId, k .. "/" .. n)
                st.lastJump = { key = key, index = k }
                -- A click is done once it lands; the held-Hyper stepping is a
                -- keyboard thing, and a room left open under the pointer is not.
                if clicked then close() else closeOrHold() end
                local shown = shownName(ctx, room, pin)
                if shown then ctx.confirmAction(shown) end
                return
            end
            ctx.log("jump gone", key, bundleId)
        end
        -- Every app here is gone: say where to fix it.
        close()
        ctx.alert(ctx.t("alert.gone",
            "The app on %s is no longer installed. Remove it in Settings > Memory Room.", label))
    end

    -- Say how putting the front app somewhere went. `pin`: where it went (or
    -- would have), named only as the room shows it.
    ---@param op RoomOp
    ---@param room Room
    ---@param pin RoomPin|nil
    ---@param app string
    local function reportPlace(op, room, pin, app)
        local where = pin and shownName(ctx, room, pin)
        if op.status == "placed" or op.status == "moved" then
            ctx.setState("room", op.json)
            if where then
                ctx.alert(ctx.t("alert.placed", "%1$s → %2$s", app, where))
            else
                ctx.alert(ctx.t("alert.inRoom", "%s is in the room", app))
            end
        elseif op.status == "already" then
            if where then
                ctx.alert(ctx.t("alert.already", "%1$s is already on %2$s", app, where))
            else
                ctx.alert(ctx.t("alert.alreadyHere", "%s is already there", app))
            end
        elseif op.status == "full" and pin then
            if where then
                ctx.alert(ctx.t("alert.full", "%1$s already holds %2$d apps. Remove one in Settings > Memory Room.",
                    where, R.MAX_APPS))
            else
                ctx.alert(ctx.t("alert.fullHere", "That place already holds %d apps. Remove one in Settings > Memory Room.",
                    R.MAX_APPS))
            end
        elseif op.status == "full" then
            ctx.alert(ctx.t("alert.roomFull", "The room already has %d places. Remove one in Settings > Memory Room.",
                R.MAX_PINS))
        elseif op.status == "noapp" then
            ctx.alert(ctx.t("alert.noApp", "No app is in front to put there."))
        end
    end

    -- Put the app in front in the place on `key`.
    local function place(key)
        local front = ctx.frontmostAppInfo()
        local op = R.place(ctx.getState("room"), key, front.bundleId)
        local room = R.decode(op.json)
        ctx.log("place", key, front.bundleId, op.status)
        close()
        reportPlace(op, room, R.pinByKey(room, key), front.name ~= "" and front.name or front.bundleId)
    end

    -- Put the app in front exactly at (x, y) of the room -- a right-click off
    -- every place: the room makes a place there for it.
    local function placeAt(x, y)
        local front = ctx.frontmostAppInfo()
        local op = R.placeAt(ctx.getState("room"), x, y, front.bundleId)
        local room = R.decode(op.json)
        local pin
        for _, p in ipairs(room.pins) do if p.id == op.id then pin = p end end
        ctx.log("placeAt", string.format("%.2f,%.2f", x, y), front.bundleId, op.status,
                pin and pin.key or "-", op.from and ("from " .. op.from) or "")
        close()
        reportPlace(op, room, pin, front.name ~= "" and front.name or front.bundleId)
    end

    -- What the drawn room reports: a click on a place ({key, app?}), the
    -- right-click's "Put <app> here" on a place ({key, action = "place"}) or off
    -- every place ({action = "placeAt", x, y}), or nil -- a click off every place,
    -- on the room or anywhere else, which closes it.
    ---@param pick {key: string|nil, app: integer|nil, action: string|nil, x: number|nil, y: number|nil}|nil
    function onPick(pick)
        if not st.modal then return end              -- a click racing the close
        if type(pick) == "table" and pick.action == "placeAt"
            and type(pick.x) == "number" and type(pick.y) == "number" then
            placeAt(pick.x, pick.y)
            return
        end
        if type(pick) ~= "table" or type(pick.key) ~= "string" then
            ctx.log("click: dismiss")
            close()
            return
        end
        ctx.log("click", pick.key, pick.action or "jump", pick.app or "-")
        if pick.action == "place" then place(pick.key) else jump(pick.key, true, pick.app) end
    end

    function st.open()
        close()
        local room = R.decode(ctx.getState("room"))
        -- A clicked room opens empty too: a right-click anywhere is how it fills.
        -- A lettered room with no places would be a mode with nothing to press.
        if #room.pins == 0 and room.showKeys then
            ctx.log("open: no places")
            ctx.alert(ctx.t("alert.noPins", "This room has no places yet. Add some in Settings > Memory Room."))
            return
        end
        -- Shift+letter places. modal.lua gives a held-leader twin only to BARE
        -- keys, so the Shift binding gets its own twin under the entry hotkey's
        -- modifiers: placing then works with Hyper still held, as jumping does.
        -- Not when the leader already has Shift: the bare key's leader twin sits
        -- on that exact combo, and binding it twice makes the seam raise.
        local trigger = ctx.actionTrigger("open")
        st.leader, st.lastJump = hotkeys.cycleModifier(trigger), nil
        local placeMods = { "shift" }
        if trigger and trigger.type == "hotkey" and type(trigger.mods) == "table" then
            for _, m in ipairs(trigger.mods) do
                if m == "shift" then placeMods = { "shift" }; break end
                placeMods[#placeMods + 1] = m
            end
        end
        local bindings = {}
        for _, pin in ipairs(room.pins) do
            local key = pin.key
            bindings[#bindings + 1] = { key = key, fn = function() jump(key) end }
            bindings[#bindings + 1] = { mods = { "shift" }, key = key, fn = function() place(key) end }
            if #placeMods > 1 then
                bindings[#bindings + 1] = { mods = placeMods, key = key, fn = function() place(key) end }
            end
        end
        ctx.log("open", #room.pins, "places", "room", room.image or "study",
                room.showKeys and "letters" or "click")
        st.modal = ctx.modal({
            silent   = true,
            bindings = bindings,
            -- A place can sit on the entry key itself (L, the door, in the default
            -- room), so every bare key gets the held-leader twin -- Hyper+L L reaches it.
            stickyExceptKey = false,
            onExit   = function()
                if st.showTimer then st.showTimer.stop() end
                if st.panel then st.panel.stop() end
                if st.releasePoll then st.releasePoll.stop() end
                st.modal, st.panel, st.showTimer, st.releasePoll, st.lastJump = nil, nil, nil, nil, nil
            end,
        })
        if not room.showKeys then
            showPanel(room)
            return
        end
        st.showTimer = ctx.afterSeconds(SHOW_DELAY, function()
            st.showTimer = nil
            showPanel(room)
        end)
    end

    return st
end

return {
    api = 1,
    id  = "memory_room",
    -- no capabilities: launchOrFocusApp / frontmostAppInfo are ungated, and the
    -- photo is read by the Swift panel, never by Lua.
    actions = {
        { id = "open", label = "Open the room",
          description = "Show the room: click a place to bring its app forward, "
              .. "right-click anywhere in it to put the app you're in there.",
          defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "l" },
          -- Not R: Hyper+R is the near-universal "reload config" in Hammerspoon
          -- setups, and a clash with another app is invisible here (Carbon lets
          -- both register; only one receives the key).
          mnemonic = "L for Loci -- the places of a memory palace",
          ---@param ctx Ctx
          run = function(ctx) ctx.perEnable(controllerFor).open() end },
    },
}
