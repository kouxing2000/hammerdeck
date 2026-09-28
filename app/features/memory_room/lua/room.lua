-- features/memory_room/room.lua
--
-- The Memory Room's ONE schema: decode, validate, default, and every edit. Pure
-- -- JSON text in, JSON text out -- with no ctx, no adapter, no clock, so both
-- writers share it: the running feature (it lays the room out on every open) and
-- the Settings page, which calls these functions through SettingsStore.readerCall
-- and only stores the string it gets back. One decoder means the page and the
-- overlay can never disagree about what a record holds.
--
-- Every op the page calls returns ONE table ({json, status}): readerCall reads a
-- single Lua result, so a second return value would never reach it.
--
-- The room holds the WINDOWS of one app at a time: each window the room has seen
-- keeps a spot on the picture, so the next time it is where it was. A record:
--   { v = 2, image = nil | "neon" | "room-ab12.jpg",
--     apps = { [bundleId] = { RoomWindow, ... } } }
-- `image` is the picture the room shows, and this module never interprets it:
-- nil is the Study, a bare id is one of the built-in rooms in assets/rooms/, and
-- a `room-*` name is the user's photo copied under <dataDir>/memory_room/ (the
-- list of built-in rooms lives with their pictures, in RoomImage.builtins,
-- swift/RoomCanvas.swift). Each app's windows are in RECENCY order -- the ones the last open saw first -- which is what
-- the cap trims from the back.

local json = require("platform.json")
local W = require("platform.windows")

local R = {}

-- Windows remembered per app. Recency is array order, so the cap drops the ones
-- no open has seen for longest -- a spot the user placed by hand last.
R.MAX_WINDOWS = 40
-- What an icon with its label covers, as a fraction of the picture: two windows
-- closer than this on both axes draw over each other.
R.FOOT = { w = 0.16, h = 0.14 }

-- Where a new window goes: the furniture every built-in room has in the same place
-- (desk, armchair, bookshelf, coffee table, window, picture, door, plant, clock --
-- the order they fill), then a grid over the rest of the picture. One list for
-- every room: on a photo they are simply well-spread spots. The door sits a little
-- in from the edge, so a label centred on it is not cut off by the frame.
R.SLOTS = {
    { x = 0.29, y = 0.46 }, { x = 0.75, y = 0.56 }, { x = 0.12, y = 0.22 },
    { x = 0.48, y = 0.80 }, { x = 0.62, y = 0.20 }, { x = 0.34, y = 0.16 },
    { x = 0.91, y = 0.48 }, { x = 0.07, y = 0.74 }, { x = 0.83, y = 0.13 },
}
-- A grid point is kept only when it clears every furniture spot by an icon's
-- footprint, so two neighbours never draw over each other.
do
    local anchors = #R.SLOTS
    for _, y in ipairs({ 0.35, 0.62, 0.90 }) do
        for _, x in ipairs({ 0.10, 0.30, 0.50, 0.70, 0.90 }) do
            local clear = true
            for i = 1, anchors do
                local s = R.SLOTS[i]
                if math.abs(s.x - x) < R.FOOT.w and math.abs(s.y - y) < R.FOOT.h then clear = false end
            end
            if clear then R.SLOTS[#R.SLOTS + 1] = { x = x, y = y } end
        end
    end
end
-- When every slot is held, a new window looks for a gap on a finer grid (top to
-- bottom, left to right) before it would share a slot.
R.GAPS = {}
for j = 0, 10 do
    for i = 0, 12 do R.GAPS[#R.GAPS + 1] = { x = 0.08 + i * 0.07, y = 0.10 + j * 0.08 } end
end

---@class RoomWindow
---@field wid integer        the OS-stable CGWindowID; 0 = unresolved
---@field pid integer|nil    the process that owned it: the wid counts only alongside it
---@field title string       its title when last seen; "" allowed
---@field x number           0..1 of the image width
---@field y number           0..1 of the image height
---@field placed boolean|nil true once the user dragged it: its spot is never given away
---@field isPrivate boolean|nil a private window's entry: held in memory, never stored (R.arrange)

---@class Room
---@field v integer
---@field image string|nil
---@field apps table<string, RoomWindow[]>

---@class RoomOp
---@field json string
---@field status string

---@class RoomSpot
---@field row table          the live window (a ctx.window.list() row)
---@field entry RoomWindow   what the room remembers for it
---@field new boolean        the room had not seen it before this open
---@field x number           where it is drawn this open: its own spot, or beside it
---@field y number
---@field aside boolean      drawn beside its spot, because another open window holds it

---@param v any
---@return number
local function unit(v)
    if type(v) ~= "number" or v ~= v then return 0.5 end   -- NaN guard
    return math.max(0, math.min(1, v))
end

---@return Room
function R.empty()
    return { v = 2, image = nil, apps = {} }
end

-- The id a window goes by on the page and in the overlay's picks: its wid, or its
-- title when the wid never resolved.
---@param e RoomWindow
---@return string
function R.windowId(e)
    if e.wid ~= 0 then return "w" .. string.format("%d", e.wid) end
    return "t:" .. e.title
end

-- The process a window row or a stored entry names; nil when it names none.
---@param t table
---@return integer|nil
local function pidOf(t)
    local n = math.tointeger(tonumber(t.pid) or 0) or 0
    return n ~= 0 and n or nil
end

---@param raw any
---@return RoomWindow|nil
local function cleanWindow(raw)
    if type(raw) ~= "table" then return nil end
    local wid = math.tointeger(tonumber(raw.wid) or 0) or 0
    local title = type(raw.title) == "string" and raw.title or ""
    if wid == 0 and title == "" then return nil end         -- nothing to find it by
    if W.isPrivate(title) then return nil end                -- never kept on disk
    return { wid = wid, pid = pidOf(raw), title = title, x = unit(raw.x), y = unit(raw.y),
             placed = raw.placed == true or nil }
end

-- Decode a stored record. MISSING or unreadable -> an empty room. A v1 record (the
-- room that held apps in places) keeps its picture; its places have no meaning in
-- a room of windows and are dropped. Bad windows are dropped one by one, and a
-- second entry for the same wid (or id) is dropped. Fields it does not know are
-- read past and not written back.
---@param raw string|nil
---@return Room
function R.decode(raw)
    local room = R.empty()
    if type(raw) ~= "string" or raw == "" then return room end
    local t = json.decode(raw)
    if type(t) ~= "table" then return room end
    room.image = (type(t.image) == "string" and t.image ~= "") and t.image or nil
    if type(t.apps) ~= "table" then return room end
    for app, list in pairs(t.apps) do
        if type(app) == "string" and app ~= "" and not W.isPrivate(nil, app) and type(list) == "table" then
            local out, ids = {}, {}
            for _, rawWin in ipairs(list) do
                local e = cleanWindow(rawWin)
                if e and not ids[R.windowId(e)] and #out < R.MAX_WINDOWS then
                    ids[R.windowId(e)] = true
                    out[#out + 1] = e
                end
            end
            if #out > 0 then room.apps[app] = out end
        end
    end
    return room
end

---@param room Room
---@return string
function R.encode(room)
    -- `apps` is tagged an OBJECT even when empty: an untagged {} encodes as [] and
    -- would decode back as an array that a bundle-id key can no longer join.
    local apps = json.asObject({})
    for app, list in pairs(room.apps) do
        local arr = {}
        for i, e in ipairs(list) do
            arr[i] = json.asObject({ wid = e.wid, pid = e.pid, title = e.title, x = e.x, y = e.y,
                                     placed = e.placed })
        end
        apps[app] = json.asArray(arr)
    end
    -- json.encode fails only on a shape bug here (the record is built above from
    -- scalars); an assert makes that loud instead of persisting nil.
    return assert(json.encode(json.asObject({ v = 2, image = room.image, apps = apps })))
end

---@param room Room
---@param status string
---@return RoomOp
local function op(room, status)
    return { json = R.encode(room), status = status }
end

-- Title parts that never tell two windows apart: a terminal's size ("80×24") and
-- login shell ("-zsh"), a size ("871 MB"), and the notes apps add after the name
-- -- Chrome's "High memory usage", a document's "Edited".
local NOISE = { ["high memory usage"] = true, ["edited"] = true }
---@param p string
---@return boolean
local function noise(p)
    return NOISE[p:lower()] ~= nil or p:match("^%d+\195\151%d+$") ~= nil or p:match("^%-%a+$") ~= nil
        or p:match("^%d+[%.,]?%d*%s?[KMGT]B$") ~= nil
end

-- What a window is called: the part of its title right BEFORE the app's own name
-- ("page - Google Chrome - profile" -> the page), or the last part when the title
-- does not name the app ("room.lua — hammerdeck" in VS Code -> the project) --
-- after dropping the noise. A project changes less than the file open in it, and
-- a label that keeps changing is one nobody learns. It is also how a window is
-- recognised after its app restarts (R.arrange), so it is kept whole here; the
-- room shortens it for display.
---@param title string
---@param appName string
---@return string
function R.nameOf(title, appName)
    -- The separators apps put between title parts: " — ", " – ", " - ", " | ". A
    -- Lua pattern class matches BYTES, so the multi-byte dashes are replaced one by one.
    local s = title:gsub(" \226\128\148 ", "\0"):gsub(" \226\128\147 ", "\0"):gsub(" %- ", "\0"):gsub(" | ", "\0")
    local want, keep, before = (appName or ""):lower(), {}, nil
    for part in (s .. "\0"):gmatch("(.-)\0") do
        local p = part:match("^%s*(.-)%s*$")
        -- The app's name, bare or with a note in parentheses ("Google Chrome (Incognito)").
        local l = p:lower()
        if p ~= "" and want ~= "" and (l == want or l:sub(1, #want + 2) == want .. " (") then
            before = before or keep[#keep]
        elseif p ~= "" and not noise(p) then
            keep[#keep + 1] = p
        end
    end
    return before or keep[#keep] or title
end

-- The longest label, in characters: about one slot wide.
R.LABEL_MAX = 16

-- The label under a window's icon: its name (R.nameOf), shortened when long. Long
-- ones keep both ends: a label wider than a slot draws over its neighbour.
---@param title string
---@param appName string
---@return string
function R.label(title, appName)
    local name = R.nameOf(title, appName)
    local n = utf8.len(name)
    if n and n > R.LABEL_MAX then
        local head = R.LABEL_MAX // 2
        -- utf8.offset in parentheses: Lua 5.5 returns a second value (the
        -- character's last byte), which sub() would take as its end.
        name = name:sub(1, (utf8.offset(name, head + 1)) - 1) .. "…"
            .. name:sub((utf8.offset(name, n - (R.LABEL_MAX - head - 1) + 1)))
    end
    return name
end

---@param list RoomWindow[]
---@param x number
---@param y number
---@return RoomWindow[] the windows an icon at (x, y) would draw over
local function under(list, x, y)
    local out = {}
    for _, e in ipairs(list) do
        if math.abs(e.x - x) < R.FOOT.w and math.abs(e.y - y) < R.FOOT.h then out[#out + 1] = e end
    end
    return out
end

-- The nearest point to (x, y) where an icon covers none of `shown`, for a window
-- whose spot `hit` holds: rings of growing radius, and on a ring the point furthest
-- along the way away from `hit`. nil when the picture has no such point.
---@param x number
---@param y number
---@param shown {x: number, y: number}[]
---@param hit {x: number, y: number}
---@return {x: number, y: number}|nil
local function beside(x, y, shown, hit)
    local ax, ay = x - hit.x, y - hit.y
    local len = math.sqrt(ax * ax + ay * ay)
    if len < 1e-6 then ax, ay = 1, 0 else ax, ay = ax / len, ay / len end
    for k = 1, 50 do
        local r = k * 0.02
        local best, bestD
        for i = 0, 31 do
            local a = i / 32 * 2 * math.pi
            local cx, cy = x + math.cos(a) * r, y + math.sin(a) * r
            if cx >= 0.03 and cx <= 0.97 and cy >= 0.05 and cy <= 0.95 and #under(shown, cx, cy) == 0 then
                local d = (cx - (x + ax * r)) ^ 2 + (cy - (y + ay * r)) ^ 2
                if not bestD or d < bestD then best, bestD = { x = cx, y = cy }, d end
            end
        end
        if best then return best end
    end
    return nil
end

-- Lay out the room for app `app` over its live windows (`live`: ctx.window.list()
-- rows of that app, most recently focused first). Each live window finds its
-- remembered entry -- by wid, then by exact title (W.matchSaved's two passes), then
-- by name (R.nameOf: after an app restart a VS Code window's title names another
-- file, but the same project) -- and keeps its spot; the entry takes the window's
-- current wid, pid and title, so from then on it is known by its new wid. A
-- remembered wid counts only while the window with it has the pid it was stored
-- with: after a reboot or logout wids are handed out again, and a new window given
-- an old one would otherwise take that window's spot for good -- so the entry
-- drops that wid and is known by its title. An entry with no pid on record is
-- taken at its wid: refusing it would re-place every window of a record that
-- carries none.
-- A window the room has never seen takes the first slot (R.SLOTS) no remembered
-- window's icon covers. When every slot is covered, it takes one covered only by
-- windows that are closed and were placed automatically, and forgets them -- a spot
-- the user placed by hand is never given away. Failing that, a gap on the finer
-- grid clear of every open or hand-placed window; failing that, the slot with the
-- fewest open windows is shared.
-- Then the open windows are drawn so that none covers another: two can want the
-- same spot (one was dragged there while the other was closed; a crowded room
-- gave a new window a closed one's spot). A spot placed by hand beats an automatic
-- one; otherwise the window seen there last keeps it. The other is drawn beside
-- it for this open only -- its own spot is unchanged, and it is drawn there again
-- once the spot is free. Returns the record to store and a spot per live window,
-- in `live` order.
-- A private window (W.isPrivate) takes part in all of this but is never stored:
-- its entry lives in `mem`, which the caller keeps in memory between opens and
-- gets back (holding only the private windows still open) as the result's `mem`.
---@param raw string|nil
---@param app string
---@param live table[]
---@param mem table<string, RoomWindow>|nil  private windows' entries by R.windowId
---@return {json: string, spots: RoomSpot[], mem: table<string, RoomWindow>}
function R.arrange(raw, app, live, mem)
    local room = R.decode(raw)
    local saved = room.apps[app] or {}
    mem = mem or {}
    local kept, private = {}, {}                       -- live rows the room may store, and not
    for _, w in ipairs(live) do
        if W.isPrivate(w.title, w.bundleID) then private[w] = true else kept[#kept + 1] = w end
    end
    local function rowId(w)
        return R.windowId({ wid = math.tointeger(tonumber(w.wid) or 0) or 0,
                            title = type(w.title) == "string" and w.title or "" })
    end
    local byWid = {}
    for _, w in ipairs(kept) do
        if w.wid and w.wid ~= 0 then byWid[w.wid] = w end
    end
    local desc = {}
    for i, e in ipairs(saved) do
        local w = e.wid ~= 0 and byWid[e.wid]
        -- Another process's window holds its wid: that wid is dead for this entry,
        -- which is known by its title from now on (and no longer shares an id with
        -- the window that has the wid now).
        if w and e.pid ~= nil and pidOf(w) ~= e.pid then e.wid = 0 end
        desc[i] = { bundleID = app, wid = e.wid, title = e.title, entry = e }
    end
    local _, pick = W.matchSaved(desc, kept)
    -- Pass 3, by name: the same matcher over what is left, each title read as its name.
    local appName = live[1] and type(live[1].appName) == "string" and live[1].appName or ""
    local taken, restSaved, restLive = {}, {}, {}
    for _, w in pairs(pick) do taken[w] = true end
    for _, d in ipairs(desc) do
        if not pick[d] then
            restSaved[#restSaved + 1] = { bundleID = app, wid = 0, title = R.nameOf(d.title, appName), d = d }
        end
    end
    for _, w in ipairs(kept) do
        if not taken[w] then
            restLive[#restLive + 1] = { bundleID = w.bundleID, wid = w.wid,
                                        title = R.nameOf(type(w.title) == "string" and w.title or "", appName), row = w }
        end
    end
    local _, byName = W.matchSaved(restSaved, restLive)
    for _, r in ipairs(restSaved) do
        if byName[r] then pick[r.d] = byName[r].row end
    end
    local bound = {}                                   -- live row -> its entry
    for _, d in ipairs(desc) do
        if pick[d] then bound[pick[d]] = d.entry end
    end
    local open = {}                                    -- entries bound to a live window
    for _, e in pairs(bound) do open[e] = true end

    local all = {}                                     -- every entry that holds a spot
    for _, e in ipairs(saved) do all[#all + 1] = e end
    local nextMem = {}
    for _, w in ipairs(live) do                        -- private windows already in memory
        local e = private[w] and mem[rowId(w)]
        if e then bound[w] = e; open[e] = true; all[#all + 1] = e; nextMem[rowId(w)] = e end
    end
    local function forget(e)
        for i, o in ipairs(all) do if o == e then table.remove(all, i); return end end
    end
    local function freeSlot()
        for _, s in ipairs(R.SLOTS) do
            if #under(all, s.x, s.y) == 0 then return s end
        end
        for _, s in ipairs(R.SLOTS) do
            local here, kept = under(all, s.x, s.y), false
            for _, e in ipairs(here) do if open[e] or e.placed then kept = true end end
            if not kept then
                for _, e in ipairs(here) do forget(e) end
                return s
            end
        end
        local held = {}                                -- what a gap must stay clear of
        for _, e in ipairs(all) do if open[e] or e.placed then held[#held + 1] = e end end
        for _, g in ipairs(R.GAPS) do
            if #under(held, g.x, g.y) == 0 then return g end
        end
        local best, fewest = R.SLOTS[1], math.huge
        for _, s in ipairs(R.SLOTS) do
            local n = 0
            for _, e in ipairs(under(all, s.x, s.y)) do if open[e] then n = n + 1 end end
            if n < fewest then best, fewest = s, n end
        end
        return best
    end

    local spots = {}
    for _, w in ipairs(live) do
        local e, new = bound[w], false
        if e then
            e.wid = math.tointeger(tonumber(w.wid) or 0) or 0
            e.pid = pidOf(w)
            e.title = type(w.title) == "string" and w.title or ""
        else
            local s = freeSlot()
            e = { wid = math.tointeger(tonumber(w.wid) or 0) or 0,
                  pid = pidOf(w),
                  title = type(w.title) == "string" and w.title or "", x = s.x, y = s.y,
                  isPrivate = private[w] or nil }
            new = true
            all[#all + 1] = e
            open[e] = true
            if e.isPrivate then nextMem[rowId(w)] = e end
        end
        spots[#spots + 1] = { row = w, entry = e, new = new, x = e.x, y = e.y, aside = false }
    end

    -- Who keeps a contested spot: hand-placed first, then the most recently seen
    -- (the saved list's order), then the windows new to the room.
    local rank = {}
    for i, e in ipairs(saved) do rank[e] = i end
    local order = {}
    for i, sp in ipairs(spots) do order[i] = sp end
    table.sort(order, function(a, b)
        if (a.entry.placed == true) ~= (b.entry.placed == true) then return a.entry.placed == true end
        local ra, rb = rank[a.entry] or math.huge, rank[b.entry] or math.huge
        if ra ~= rb then return ra < rb end
        return (a.row.wid or 0) < (b.row.wid or 0)
    end)
    local shown = {}
    for _, sp in ipairs(order) do
        local hit = under(shown, sp.x, sp.y)[1]
        if hit then
            local p = beside(sp.x, sp.y, shown, hit)
            if p then sp.x, sp.y, sp.aside = p.x, p.y, true end
        end
        shown[#shown + 1] = { x = sp.x, y = sp.y }
    end

    -- Recency: this open's windows first (most recently focused first), then the
    -- rest as they were; the cap trims the tail.
    local list, seen = {}, {}
    for _, s in ipairs(spots) do
        if not seen[s.entry] and not s.entry.isPrivate and cleanWindow(s.entry) then
            list[#list + 1] = s.entry; seen[s.entry] = true
        end
    end
    for _, e in ipairs(all) do
        if not seen[e] and not e.isPrivate then list[#list + 1] = e; seen[e] = true end
    end
    while #list > R.MAX_WINDOWS do
        local drop = #list
        for i = #list, 1, -1 do
            if not list[i].placed then drop = i; break end
        end
        table.remove(list, drop)
    end
    room.apps[app] = #list > 0 and list or nil
    return { json = R.encode(room), spots = spots, mem = nextMem }
end

-- Move window `id` (R.windowId) of app `app` to (x, y). The spot is now the user's:
-- it is kept for the window while it is closed, and no other window is given it.
---@return RoomOp  status "moved" | "nowindow"
function R.move(raw, app, id, x, y)
    local room = R.decode(raw)
    for _, e in ipairs(room.apps[app] or {}) do
        if R.windowId(e) == id then
            e.x, e.y, e.placed = unit(x), unit(y), true
            return op(room, "moved")
        end
    end
    return op(room, "nowindow")
end

-- Forget window `id` (R.windowId) of app `app`: its entry goes, spot and all. A
-- window still open is simply new to the room the next time it opens.
---@return RoomOp  status "forgot" | "nowindow"
function R.forget(raw, app, id)
    local room = R.decode(raw)
    local list = room.apps[app] or {}
    for i, e in ipairs(list) do
        if R.windowId(e) == id then
            table.remove(list, i)
            room.apps[app] = #list > 0 and list or nil
            return op(room, "forgot")
        end
    end
    return op(room, "nowindow")
end

-- The apps whose room keeps a spot the user placed, for the Settings page.
---@param raw string|nil
---@return string[] bundle ids
function R.keptApps(raw)
    local out = {}
    for app, list in pairs(R.decode(raw).apps) do
        for _, e in ipairs(list) do
            if e.placed then out[#out + 1] = app; break end
        end
    end
    table.sort(out)
    return json.asArray(out)
end

-- The spots the user placed in app `app`'s room, drawn as the room draws them:
-- {id, name, title, x, y} each, `name` the label (R.label over `appName`).
---@param raw string|nil
---@param app string
---@param appName string
---@return table[]
function R.kept(raw, app, appName)
    local out = {}
    for _, e in ipairs(R.decode(raw).apps[app] or {}) do
        if e.placed then
            out[#out + 1] = json.asObject({ id = R.windowId(e), name = R.label(e.title, appName),
                                            title = e.title, x = e.x, y = e.y })
        end
    end
    return json.asArray(out)
end

-- Point the room at another picture: a built-in room's id, a photo's filename
-- under <dataDir>/memory_room/, or "" for the Study. Spots stay put: they are
-- fractions, so they land in the same relative places on any picture.
---@return RoomOp  status "image"
function R.setImage(raw, image)
    local room = R.decode(raw)
    room.image = (type(image) == "string" and image ~= "") and image or nil
    return op(room, "image")
end

return R
