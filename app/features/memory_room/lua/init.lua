-- features/memory_room
--
-- A memory palace for ONE app's windows. When an app has many windows that look
-- alike (five VS Code projects, a pile of Terminal tabs), Hyper+L shows a room
-- holding only that app's windows, each at a spot it keeps: the first time the
-- room sees a window it gives it a free spot (the furniture first, then the rest
-- of the picture), and from then on the window is there -- found by WHERE it
-- lives, not by reading titles. App Exposé shows the same windows, but laid out
-- fresh every time.
--
-- The room is POINTED AT: Hyper+L draws it at once, hovering a window shows its
-- full title (and its picture, when Screen Recording allows), a click brings it
-- forward, dragging one moves its spot, and a click anywhere else -- or Escape --
-- closes it. The keyboard way to a window is the Window Switcher.
--
-- The record is owned by room.lua, which the Settings page calls too.

local json = require("platform.json")
local R = require("features.memory_room.room")

---@param ctx Ctx
---@param room Room
---@param spots RoomSpot[]
---@param appName string
---@return table
local function panelSpec(ctx, room, spots, appName)
    local focused = ctx.window.focusedWid()
    local pins, front = {}, nil
    for _, s in ipairs(spots) do
        local e, id = s.entry, R.windowId(s.entry)
        if focused and focused ~= 0 and e.wid == focused then front = id end
        -- wid: the window's picture, when the room shows one on hover.
        pins[#pins + 1] = json.asObject({ id = id, wid = s.row.wid,
                                          name = R.label(e.title, appName), title = e.title, x = s.x, y = s.y,
                                          apps = json.asArray({ s.row.bundleID or "" }) })
    end
    return json.asObject({
        title = appName,
        image = room.image,
        pins  = json.asArray(pins),
        front = front,
        -- How close two spots may be: a drop lands clear of this, so the next open
        -- does not find the two covering each other and draw one aside.
        foot  = json.asObject({ w = R.FOOT.w, h = R.FOOT.h }),
        hint  = ctx.t("panel.hint", "click: bring it forward    drag: move it    esc: close"),
    })
end

---@param ctx Ctx
local function controllerFor(ctx)
    -- mem: each app's private windows (R.arrange), held here and never stored.
    local st = { mem = {} }

    -- What the log may say about window `id`: a private window's id can carry its
    -- title (a window with no wid goes by it), and the log is written to disk.
    local function logId(id)
        local s = st.byId and st.byId[id]
        return (s and s.entry.isPrivate) and "private" or id
    end

    local function close()
        if st.modal then st.modal.stop() end        -- onExit clears the rest
    end

    -- Bring window `id` (R.windowId) forward. The row is the one this open listed:
    -- its id stays good across later listings (the bridge keys it by wid), so a
    -- click needs no second walk over every app's windows.
    local function focus(id)
        local spot = st.byId and st.byId[id]
        if not spot then close(); return end
        local ok = ctx.window.focus(spot.row.id)
        ctx.log("focus", logId(id), ok and "ok" or "gone")
        close()
        if not ok then
            ctx.alert(ctx.t("alert.gone", "That window is no longer open."))
        end
    end

    -- Drag: the window keeps its new spot; the room stays open.
    local function move(id, x, y)
        local s = st.byId and st.byId[id]
        if s and s.entry.isPrivate then                -- its entry is the one in st.mem
            s.entry.x, s.entry.y, s.entry.placed = x, y, true
            ctx.log("move private", string.format("%.2f,%.2f", x, y), "(memory only)")
            return
        end
        local op = R.move(ctx.getState("room"), st.app, id, x, y)
        ctx.log("move", id, string.format("%.2f,%.2f", x, y), op.status)
        if op.status == "moved" then ctx.setState("room", op.json) end
    end

    -- What the drawn room reports: a click on a window ({id}), a drag that let go
    -- ({id, action = "move", x, y}), or nil -- a click off every window, on the
    -- room or anywhere else, which closes it.
    ---@param pick {id: string|nil, action: string|nil, x: number|nil, y: number|nil}|nil
    local function onPick(pick)
        if not st.modal then return end              -- a click racing the close
        if type(pick) ~= "table" or type(pick.id) ~= "string" then
            ctx.log("click: dismiss")
            close()
            return
        end
        if pick.action == "move" and type(pick.x) == "number" and type(pick.y) == "number" then
            move(pick.id, pick.x, pick.y)
            return
        end
        ctx.log("click", logId(pick.id))
        focus(pick.id)
    end

    function st.open()
        close()
        local front = ctx.frontmostAppInfo()
        if front.bundleId == "" then
            ctx.log("open: no app in front")
            ctx.alert(ctx.t("alert.noApp", "No app is in front."))
            return
        end
        local appName = front.name ~= "" and front.name or front.bundleId
        local rows = ctx.window.list()
        -- Empty for three different reasons, each with its own way out: no
        -- Accessibility grant (nothing lists at all), the app not answering in time,
        -- or genuinely no windows.
        if #rows == 0 and not ctx.axTrusted() then
            ctx.log("open: no accessibility")
            ctx.alert(ctx.t("alert.needsAccess", "Memory Room needs Accessibility to see your windows."))
            ctx.axPrompt()
            return
        end
        local live = {}
        for _, w in ipairs(rows) do
            if w.bundleID == front.bundleId then live[#live + 1] = w end
        end
        if #live == 0 then
            local dropped = false
            for _, b in ipairs(ctx.window.droppedApps()) do
                if b == front.bundleId then dropped = true end
            end
            ctx.log("open: no windows", front.bundleId, dropped and "(did not answer)" or "")
            if dropped then
                ctx.alert(ctx.t("alert.noAnswer", "%s did not answer in time. Try again.", appName))
            else
                ctx.alert(ctx.t("alert.noWindows", "%s has no open windows.", appName))
            end
            return
        end

        local arranged = R.arrange(ctx.getState("room"), front.bundleId, live, st.mem[front.bundleId])
        st.mem[front.bundleId] = next(arranged.mem) and arranged.mem or nil
        ctx.setState("room", arranged.json)
        local room = R.decode(arranged.json)
        local fresh, aside, private = 0, {}, 0
        st.app, st.byId = front.bundleId, {}
        for _, s in ipairs(arranged.spots) do
            st.byId[R.windowId(s.entry)] = s
            if s.new then fresh = fresh + 1 end
            if s.entry.isPrivate then private = private + 1 end
        end
        for _, s in ipairs(arranged.spots) do
            if s.aside then aside[#aside + 1] = logId(R.windowId(s.entry)) end
        end
        ctx.log("open", front.bundleId, #live, "windows", fresh, "new", "room", room.image or "study",
                private > 0 and (private .. " private (memory only)") or "",
                #aside > 0 and ("aside " .. table.concat(aside, ",")) or "")

        -- A mode with no keys of its own: it holds Escape while the room is open.
        st.modal = ctx.modal({
            silent   = true,
            bindings = {},
            onExit   = function()
                if st.panel then st.panel.stop() end
                st.modal, st.panel, st.app, st.byId = nil, nil, nil, nil
            end,
        })
        st.panel = ctx.roomPanel(panelSpec(ctx, room, arranged.spots, appName), onPick)
    end

    return st
end

return {
    api = 1,
    id  = "memory_room",
    -- no capabilities: window listing / focus and frontmostAppInfo are ungated,
    -- and the photo is read by the Swift panel, never by Lua.
    actions = {
        { id = "open", label = "Open the room",
          description = "Show the room of the app you're in: click a window to bring it forward, "
              .. "drag one to move its spot.",
          defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "l" },
          -- Not R: Hyper+R is the near-universal "reload config" in Hammerspoon
          -- setups, and a clash with another app is invisible here (Carbon lets
          -- both register; only one receives the key).
          mnemonic = "L for Loci -- the places of a memory palace",
          ---@param ctx Ctx
          run = function(ctx) ctx.perEnable(controllerFor).open() end },
    },
}
