-- features/memory_room/room.lua
--
-- The Memory Room's ONE schema: decode, validate, default, and every edit. Pure
-- -- JSON text in, JSON text out -- with no ctx, no adapter, no clock, so both
-- writers share it: the running feature (Shift+letter places an app) and the
-- Settings page, which calls these functions through SettingsStore.readerCall
-- and only stores the string it gets back. One decoder means the page and the
-- overlay can never disagree about what a record holds.
--
-- Every op the page calls returns ONE table ({json, status, id?}): readerCall
-- reads a single Lua result, so a second return value would never reach it.
--
-- A record:
--   { v = 1, image = nil | "neon" | "room-ab12.jpg", pins = { RoomPin, ... } }
-- `image` is the picture the room shows, and this module never interprets it:
-- nil is the Study, a bare id is one of the built-in rooms in assets/rooms/, and
-- a `room-*` name is the user's photo copied under <dataDir>/memory_room/. The
-- list of built-in rooms lives with their pictures, in RoomImage.builtins
-- (swift/RoomCanvas.swift). Every built-in room has the same furniture in the
-- same spots, so one set of places fits all of them. Pin x/y are fractions of
-- the image (0..1, top-left).

local json = require("platform.json")

local R = {}

R.MAX_PINS = 30
R.MAX_APPS = 3
-- The three letter rows of a US keyboard, top to bottom. A pin's key comes from
-- where it sits: the photo's top third is the top row, left to right -- so the
-- letter itself is spatial, and the room reads like the keyboard under your hand.
R.ROWS = { "qwertyuiop", "asdfghjkl;", "zxcvbnm,./" }

---@class RoomPin
---@field id string
---@field name string        user-given; "" allowed
---@field nameKey string|nil a default pin's i18n name (dropped once renamed)
---@field key string         one character from R.ROWS
---@field x number           0..1 of the image width
---@field y number           0..1 of the image height
---@field apps string[]      bundle ids, placement order, at most R.MAX_APPS

---@class Room
---@field v integer
---@field image string|nil
---@field pins RoomPin[]

---@class RoomOp
---@field json string
---@field status string
---@field id string|nil
---@field from string|nil    place(): the pin the app moved from

local VALID_KEY = {}
for _, row in ipairs(R.ROWS) do
    for i = 1, #row do VALID_KEY[row:sub(i, i)] = true end
end

---@param v any
---@return number
local function unit(v)
    if type(v) ~= "number" or v ~= v then return 0.5 end   -- NaN guard
    return math.max(0, math.min(1, v))
end

-- The default room: the illustrated study in assets/rooms/study.jpg (and every
-- other built-in room, drawn to the same layout). Keys are
-- chosen by hand to sit near where their furniture is (the same rule a dropped
-- pin follows), nudged onto a mnemonic where the position allows -- D is the
-- desk. The coordinates are tied to that image; test/cases/memory_room.lua pins
-- the count and key validity so a swap of the image cannot silently orphan them.
local DEFAULT_PINS = {
    { nameKey = "bookshelf", name = "Bookshelf",    key = "w", x = 0.12, y = 0.22 },
    { nameKey = "picture",   name = "Picture",      key = "r", x = 0.34, y = 0.16 },
    { nameKey = "window",    name = "Window",       key = "u", x = 0.62, y = 0.20 },
    { nameKey = "clock",     name = "Clock",        key = "o", x = 0.83, y = 0.13 },
    { nameKey = "desk",      name = "Desk",         key = "d", x = 0.29, y = 0.46 },
    { nameKey = "armchair",  name = "Armchair",     key = "k", x = 0.75, y = 0.56 },
    { nameKey = "door",      name = "Door",         key = "l", x = 0.94, y = 0.48 },
    { nameKey = "plant",     name = "Plant",        key = "z", x = 0.07, y = 0.74 },
    { nameKey = "table",     name = "Coffee table", key = "b", x = 0.48, y = 0.80 },
}

---@return Room
function R.default()
    local pins = {}
    for i, p in ipairs(DEFAULT_PINS) do
        pins[i] = { id = "p" .. i, name = p.name, nameKey = p.nameKey, key = p.key,
                    x = p.x, y = p.y, apps = {} }
    end
    return { v = 1, image = nil, pins = pins }
end

---@param raw any
---@return RoomPin|nil
local function cleanPin(raw, usedKeys, usedIds)
    if type(raw) ~= "table" then return nil end
    local key = type(raw.key) == "string" and raw.key:lower() or nil
    local id = raw.id
    if not key or not VALID_KEY[key] or usedKeys[key] then return nil end
    if type(id) ~= "string" or id == "" or usedIds[id] then return nil end
    local apps, seen = {}, {}
    if type(raw.apps) == "table" then
        for _, a in ipairs(raw.apps) do
            if type(a) == "string" and a ~= "" and not seen[a] and #apps < R.MAX_APPS then
                seen[a] = true
                apps[#apps + 1] = a
            end
        end
    end
    usedKeys[key], usedIds[id] = true, true
    return { id = id, key = key, x = unit(raw.x), y = unit(raw.y), apps = apps,
             name = type(raw.name) == "string" and raw.name or "",
             nameKey = type(raw.nameKey) == "string" and raw.nameKey or nil }
end

-- Decode a stored record. MISSING or unreadable -> the default room; a record
-- that decodes keeps exactly what it says, so a user who removed every pin gets
-- an empty room back, never the default resurrected. Bad pins are dropped one
-- by one (a duplicate key, a key off the three rows, a missing id) rather than
-- failing the whole record, and an app placed on two pins stays on the first.
---@param raw string|nil
---@return Room
function R.decode(raw)
    if type(raw) ~= "string" or raw == "" then return R.default() end
    local t = json.decode(raw)
    if type(t) ~= "table" or type(t.pins) ~= "table" then return R.default() end
    local room = { v = 1, pins = {},
                   image = (type(t.image) == "string" and t.image ~= "") and t.image or nil }
    local usedKeys, usedIds, placed = {}, {}, {}
    for _, p in ipairs(t.pins) do
        if #room.pins >= R.MAX_PINS then break end
        local pin = cleanPin(p, usedKeys, usedIds)
        if pin then
            local kept = {}
            for _, a in ipairs(pin.apps) do
                if not placed[a] then placed[a] = true; kept[#kept + 1] = a end
            end
            pin.apps = kept
            room.pins[#room.pins + 1] = pin
        end
    end
    return room
end

---@param room Room
---@return string
function R.encode(room)
    local pins = {}
    for i, p in ipairs(room.pins) do
        pins[i] = json.asObject({ id = p.id, name = p.name, nameKey = p.nameKey, key = p.key,
                                  x = p.x, y = p.y, apps = json.asArray(p.apps) })
    end
    -- json.encode fails only on a shape bug here (the record is built above from
    -- scalars); an assert makes that loud instead of persisting nil.
    local out = assert(json.encode(json.asObject({ v = 1, image = room.image,
                                                   pins = json.asArray(pins) })))
    return out
end

---@param room Room
---@param key string
---@return RoomPin|nil
function R.pinByKey(room, key)
    for _, p in ipairs(room.pins) do if p.key == key then return p end end
    return nil
end

---@param room Room
---@param id string
---@return RoomPin|nil
local function pinById(room, id)
    for _, p in ipairs(room.pins) do if p.id == id then return p end end
    return nil
end

-- The key a pin dropped at (x, y) gets: the letter under that spot (row band by
-- y, column by x), or -- when another pin holds it -- the nearest free letter in
-- the same row (left wins a tie), then the nearest rows. nil when all 30 are used.
---@param room Room
---@param x number
---@param y number
---@return string|nil
function R.keyFor(room, x, y)
    local used = {}
    for _, p in ipairs(room.pins) do used[p.key] = true end
    local row = math.min(3, math.floor(unit(y) * 3) + 1)
    local col = math.min(10, math.floor(unit(x) * 10) + 1)
    local rowOrder = ({ { 1, 2, 3 }, { 2, 1, 3 }, { 3, 2, 1 } })[row]
    for _, r in ipairs(rowOrder) do
        local letters = R.ROWS[r]
        for d = 0, 9 do
            for _, c in ipairs(d == 0 and { col } or { col - d, col + d }) do
                if c >= 1 and c <= 10 then
                    local k = letters:sub(c, c)
                    if not used[k] then return k end
                end
            end
        end
    end
    return nil
end

---@param room Room
---@return string
local function nextId(room)
    local n = 0
    for _, p in ipairs(room.pins) do
        local k = tonumber(p.id:match("^p(%d+)$"))
        if k and k > n then n = k end
    end
    return "p" .. (n + 1)
end

---@param room Room
---@param status string
---@param extra table|nil
---@return RoomOp
local function op(room, status, extra)
    local out = { json = R.encode(room), status = status }
    for k, v in pairs(extra or {}) do out[k] = v end
    return out
end

---@param raw string|nil
---@param x number
---@param y number
---@param name string|nil
---@return RoomOp  status "added" | "full"
function R.addPin(raw, x, y, name)
    local room = R.decode(raw)
    local key = #room.pins < R.MAX_PINS and R.keyFor(room, x, y) or nil
    if not key then return op(room, "full") end
    local id = nextId(room)
    room.pins[#room.pins + 1] = { id = id, key = key, x = unit(x), y = unit(y), apps = {},
                                  name = type(name) == "string" and name or "" }
    return op(room, "added", { id = id })
end

-- Moving a pin never changes its key: the letter is what the user has learned,
-- and re-deriving it from the new spot would silently move their memory.
---@return RoomOp  status "moved" | "nopin"
function R.movePin(raw, id, x, y)
    local room = R.decode(raw)
    local p = pinById(room, id)
    if not p then return op(room, "nopin") end
    p.x, p.y = unit(x), unit(y)
    return op(room, "moved")
end

---@return RoomOp  status "renamed" | "nopin"
function R.renamePin(raw, id, name)
    local room = R.decode(raw)
    local p = pinById(room, id)
    if not p then return op(room, "nopin") end
    p.name, p.nameKey = type(name) == "string" and name or "", nil
    return op(room, "renamed")
end

-- Give pin `id` the key `key`; a pin already holding it takes this pin's old key
-- (a swap), so no edit can ever leave two places on one letter.
---@return RoomOp  status "rekeyed" | "swapped" | "badkey" | "nopin"
function R.setKey(raw, id, key)
    local room = R.decode(raw)
    local p = pinById(room, id)
    if not p then return op(room, "nopin") end
    key = type(key) == "string" and key:lower() or ""
    if not VALID_KEY[key] then return op(room, "badkey") end
    local holder = R.pinByKey(room, key)
    if holder and holder ~= p then
        holder.key, p.key = p.key, key
        return op(room, "swapped", { id = holder.id })
    end
    p.key = key
    return op(room, "rekeyed")
end

---@return RoomOp  status "removed" | "nopin"
function R.removePin(raw, id)
    local room = R.decode(raw)
    for i, p in ipairs(room.pins) do
        if p.id == id then
            table.remove(room.pins, i)
            return op(room, "removed")
        end
    end
    return op(room, "nopin")
end

-- Point the room at another picture: a built-in room's id, a photo's filename
-- under <dataDir>/memory_room/, or "" for the Study. Pins stay put: they are
-- fractions, so they land in the same relative spots -- exactly right on every
-- built-in room, and on a photo the user drags whichever ones no longer fit.
---@return RoomOp  status "image"
function R.setImage(raw, image)
    local room = R.decode(raw)
    room.image = (type(image) == "string" and image ~= "") and image or nil
    return op(room, "image")
end

-- Put app `bundleId` in the place on `key`. An app lives in ONE place, so
-- placing it elsewhere moves it; a full place refuses and leaves the app where
-- it was (checked BEFORE the move, or a refused place would still unplace it).
---@return RoomOp  status "placed" | "moved" | "already" | "full" | "nopin" | "noapp"
function R.place(raw, key, bundleId)
    local room = R.decode(raw)
    local pin = R.pinByKey(room, key)
    if not pin then return op(room, "nopin") end
    if type(bundleId) ~= "string" or bundleId == "" then return op(room, "noapp") end
    for _, a in ipairs(pin.apps) do
        if a == bundleId then return op(room, "already", { id = pin.id }) end
    end
    if #pin.apps >= R.MAX_APPS then return op(room, "full", { id = pin.id }) end
    local from
    for _, p in ipairs(room.pins) do
        for i, a in ipairs(p.apps) do
            if a == bundleId then table.remove(p.apps, i); from = p.id; break end
        end
    end
    pin.apps[#pin.apps + 1] = bundleId
    return op(room, from and "moved" or "placed", { id = pin.id, from = from })
end

---@return RoomOp  status "unplaced" | "nopin" | "absent"
function R.unplace(raw, id, bundleId)
    local room = R.decode(raw)
    local p = pinById(room, id)
    if not p then return op(room, "nopin") end
    for i, a in ipairs(p.apps) do
        if a == bundleId then
            table.remove(p.apps, i)
            return op(room, "unplaced")
        end
    end
    return op(room, "absent")
end

-- Which of a place's apps a press should bring forward: the one after the app
-- that is already frontmost (so pressing the letter again steps through the
-- place in the order apps were put there), else the first. Stepping keys off
-- what is in FRONT, not a counter, so it survives leaving and re-entering the
-- room and never drifts from what the user is looking at.
---@param pin RoomPin
---@param frontmostId string|nil
---@return integer|nil  nil for an empty place
function R.nextIndex(pin, frontmostId)
    local n = #pin.apps
    if n == 0 then return nil end
    for i, a in ipairs(pin.apps) do
        if a == frontmostId then return i % n + 1 end
    end
    return 1
end

return R
