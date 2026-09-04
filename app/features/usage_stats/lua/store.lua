-- features/usage_stats/store.lua
--
-- The usage-data FORMAT: pure functions for the on-disk CSV layout shared by
-- BOTH the live tracker (init.lua) and the historical report reader (report.lua),
-- so the parse / dir-resolution / aggregation logic has exactly one home and the
-- two readers can never drift.
--
-- Layout (under the resolved storage root `base`):
--   <base>/YYYY-MM/YYYY-MM-DD.csv        sessions (wake_time,sleep_time,duration_min)
--   <base>/YYYY-MM/YYYY-MM-DD-apps.csv   per-app focus seconds (app,context,seconds)
--
-- PURE LEAF MODULE: no require of any stateful platform module (adapter / ctx /
-- registry). File IO is INJECTED -- callers pass a `read(path)` closure (the
-- tracker passes ctx.fileRead; the report passes adapter.fileRead) -- so this
-- module stays a testable, side-effect-free format library.

local M = {}

M.DAY_LABELS = { "S", "M", "T", "W", "T", "F", "S" }

-- CSV (RFC 4180) field-quoting for the apps file. An app name ("Excel, Inc.")
-- or a title-derived context can contain a comma; quote any field with a comma,
-- quote, or newline and double its internal quotes, so a row never shifts
-- columns on reload. seconds is always a clean integer (never quoted), so the
-- trailing ",(%d+)$" total-scan in readDayTotal still finds the total.
function M.csvField(s)
    if s:find('[",\n]') then
        return '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end

-- Parse one apps-CSV data row -> app, context, (number) seconds; nil if
-- malformed. Honors quoted fields with escaped ("") quotes.
function M.parseAppsRow(line)
    local fields, i, n = {}, 1, #line
    while i <= n do
        local field
        if line:sub(i, i) == '"' then
            i = i + 1
            local buf = {}
            while i <= n do
                local c = line:sub(i, i)
                if c == '"' then
                    if line:sub(i + 1, i + 1) == '"' then
                        buf[#buf + 1] = '"'; i = i + 2
                    else
                        i = i + 1; break
                    end
                else
                    buf[#buf + 1] = c; i = i + 1
                end
            end
            field = table.concat(buf)
        else
            local j = line:find(",", i, true) or (n + 1)
            field = line:sub(i, j - 1)
            i = j
        end
        fields[#fields + 1] = field
        if line:sub(i, i) == "," then i = i + 1 end
    end
    local secs = tonumber(fields[3])
    if not (fields[1] and secs) then return nil end
    return fields[1], fields[2] or "", secs
end

-- Storage root, resolved from the `dir` option: a leading ~ expanded against
-- `home` (the caller never reads HOME itself). Empty falls back to the default.
-- A non-absolute result (a bare relative path, no ~ or /) would otherwise write
-- relative to the app CWD AND silently disable retention (removeSubdir only
-- sweeps absolute, under-home bases), so anchor it under home.
function M.resolveDir(dirOpt, home)
    if not dirOpt or dirOpt == "" then dirOpt = "~/.computer-usage" end
    local base
    if dirOpt == "~" then
        base = home
    else
        local rest = dirOpt:match("^~/(.*)$")
        base = rest and (home .. "/" .. rest) or dirOpt
    end
    if not base:match("^/") then base = home .. "/" .. base end
    return base
end

-- Path builders (months live directly under `base`; the chosen folder IS the
-- usage folder, no extra "usage/" segment).
function M.dateStr(t)        return os.date("%Y-%m-%d", t) end

--- `n` epoch timestamps, oldest first, one per calendar day ending on the day
--- `now` falls in -- each anchored at LOCAL NOON.
---
--- Noon is the whole point. A calendar day is 23 or 25 hours across a DST
--- transition, so stepping back by a fixed 86400s from an arbitrary time of day
--- can land on the date you just left: taken at 23:00 on a 25-hour day it
--- repeats that date and drops the oldest one, silently making an "N-day" window
--- cover N-1 days. From noon, an hour either way cannot cross midnight.
--- (report.lua's isoToTime anchors at noon for exactly this reason.)
---@param now integer   epoch seconds
---@param n integer     how many days, including today
---@return integer[]
function M.dayAnchors(now, n)
    local d = os.date("*t", now)
    local noon = os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })
    local out = {}
    for i = n - 1, 0, -1 do out[#out + 1] = noon - i * 86400 end
    return out
end
function M.monthDir(base, d) return base .. "/" .. d:sub(1, 7) end
function M.appsPath(base, d) return M.monthDir(base, d) .. "/" .. d .. "-apps.csv" end
function M.sessionsPath(base, d) return M.monthDir(base, d) .. "/" .. d .. ".csv" end

-- Total focus seconds recorded for a day, scanned straight from the apps CSV's
-- trailing integer column (cheap; no full row parse). `read` is the injected
-- file reader. Past days never change, so callers may cache the result.
function M.readDayTotal(read, base, d)
    local total, body = 0, read(M.appsPath(base, d))
    if body then
        for line in body:gmatch("[^\n]+") do
            local v = line:match(",(%d+)$")
            if v then total = total + tonumber(v) end
        end
    end
    return total
end

-- Read a day's apps CSV via the injected `read` and ADD its rows into the
-- accumulator `acc` ("app\tcontext" -> seconds), summing across days. Returns
-- the day's total seconds. Used by the range report to roll many days into one
-- aggregate map.
function M.accumulateDay(read, base, d, acc)
    local body = read(M.appsPath(base, d))
    if not body then return 0 end
    local total, first = 0, true
    for line in body:gmatch("[^\n]+") do
        if first then
            first = false
        else
            local app, context, secs = M.parseAppsRow(line)
            if app then
                acc[app .. "\t" .. context] = (acc[app .. "\t" .. context] or 0) + secs
                total = total + secs
            end
        end
    end
    return total
end

-- Aggregate an "app\tcontext" -> seconds map into ranked app rows, each with its
-- context sub-rows. `topApps` / `topContexts` cap the lists (nil = uncapped: the
-- live widget caps, the range report keeps the full ranking). One implementation
-- for both the tracker's snapshot() and the report.
function M.aggregate(appTime, topApps, topContexts)
    local byApp, rows = {}, {}
    for key, secs in pairs(appTime) do
        local app, context = key:match("^(.-)\t(.*)$")
        app = app or key
        local g = byApp[app]
        if not g then
            g = { app = app, secs = 0, contexts = {} }
            byApp[app] = g
            rows[#rows + 1] = g
        end
        g.secs = g.secs + secs
        if context and context ~= "" then
            g.contexts[#g.contexts + 1] = { name = context, secs = math.floor(secs) }
        end
    end
    table.sort(rows, function(a, b) return a.secs > b.secs end)
    while topApps and #rows > topApps do rows[#rows] = nil end
    for _, g in ipairs(rows) do
        g.secs = math.floor(g.secs)
        table.sort(g.contexts, function(a, b) return a.secs > b.secs end)
        if topContexts then
            while #g.contexts > topContexts do g.contexts[#g.contexts] = nil end
        end
    end
    return rows
end

return M
