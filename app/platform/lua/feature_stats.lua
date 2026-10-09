-- platform/feature_stats -- the opt-in feature statistics an update check may carry.
--
-- CORE tier: only the registry requires it (it is not on the feature allowlist).
-- Nothing is counted unless the user turned sharing on, and nothing leaves the
-- Mac from here: the Swift updater delegate reads `report` at update-check time
-- and Sparkle appends it to the feed request.
--
-- Built-in features only. An extension's id is a folder name the user typed, so
-- it is never counted and never listed.
--
-- Counts are kept per UTC day in two slots, the day in progress and the newest
-- earlier day that had any use. A report always sends that earlier, complete day
-- together with its date, so the reader dedupes on (install id, day) -- which is
-- why no "already sent" state exists here: a check that finds no update ends in
-- an error, so a send could not be confirmed anyway.

local adapter = require("platform.adapter")
local json    = require("platform.json")

local M = {}

M.SHARE_KEY  = "hammerdeck.stats.share"
M.COUNTS_KEY = "hammerdeck.stats.counts"

local function utcDay(t) return os.date("!%Y-%m-%d", t) end

-- 1-9 -> "1", 10-99 -> "2", 100+ -> "3". A feature that never fired is simply
-- absent; the "on" list says which features could have.
function M.bucket(n)
    if n >= 100 then return "3" elseif n >= 10 then return "2" else return "1" end
end

-- A slot that is not {day = "YYYY-MM-DD", counts = {...}} is dropped rather than
-- trusted: this value is read on every fire.
local function slot(v)
    if type(v) == "table" and type(v.day) == "string" and type(v.counts) == "table" then
        return v
    end
    return nil
end

local function load()
    local raw = adapter.getSetting(M.COUNTS_KEY, nil)
    local ok, v = pcall(json.decode, raw or "")
    if not ok or type(v) ~= "table" then v = {} end
    return { cur = slot(v.cur), prev = slot(v.prev) }
end

-- Move a finished day into `prev`. A day with no use never becomes a slot, so
-- `prev` is always the newest day that had something to report.
local function roll(s, today)
    if s.cur and s.cur.day ~= today then
        s.prev, s.cur = s.cur, nil
    end
    return s
end

function M.isSharing()
    return adapter.getSetting(M.SHARE_KEY, false) == true
end

--- Count one successful fire of a feature's action. The registry calls this only for
--- fires the user made; schedules, events, rules and agent runs never get here.
---@param m table the registered feature manifest
---@param t integer seconds since the epoch (adapter.now())
function M.note(m, t)
    if m.extension or not M.isSharing() then return end
    local today = utcDay(t)
    local s = roll(load(), today)
    s.cur = s.cur or { day = today, counts = json.asObject({}) }
    s.cur.counts[m.id] = (s.cur.counts[m.id] or 0) + 1
    adapter.setSetting(M.COUNTS_KEY, json.encode(json.asObject({
        cur = s.cur and json.asObject(s.cur), prev = s.prev and json.asObject(s.prev),
    })))
end

--- The newest complete day with use, as {day = "2026-10-08", use = "id:1,id:2"},
--- or nil when there is none. Ids are sorted so the same day reads the same way
--- on every check.
---@param t integer seconds since the epoch
---@return {day: string, use: string}|nil
function M.report(t)
    local s = roll(load(), utcDay(t))
    if not s.prev or type(s.prev.counts) ~= "table" then return nil end
    local ids = {}
    for id in pairs(s.prev.counts) do ids[#ids + 1] = id end
    table.sort(ids)
    local parts = {}
    for _, id in ipairs(ids) do
        parts[#parts + 1] = id .. ":" .. M.bucket(s.prev.counts[id])
    end
    if #parts == 0 then return nil end
    return { day = s.prev.day, use = table.concat(parts, ",") }
end

--- Forget every count (sharing turned off, or the install id reset).
function M.clear()
    adapter.setSetting(M.COUNTS_KEY, nil)
end

return M
