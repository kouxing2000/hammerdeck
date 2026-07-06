-- test/harness.lua -- shared setup + the `t` handle for the headless test suite.
--
-- Owns what the top of run.lua used to: the co-located loader install, the fake
-- adapter + seam preempt, the real platform requires, the deterministic clock
-- pin, the single assertion counter, and the shared helpers. Both the
-- (transitional) monolith run.lua and each migrating test/cases/<id>.lua source
-- their ok()/fake/registry/helpers from here, so ONE `passed` total spans them
-- all. It also owns the per-case world reset (freshWorld) the runner will call.
--
-- Phase 0 of docs/specs/RUN_LUA_SPLIT_SPEC.md: setup + helpers extracted, no
-- behavior change (the monolith still runs inline). The discover()/runner loop
-- lands in Phase 1.

package.path = "app/?.lua;app/?/init.lua;test/?.lua;" .. package.path
require("loader").install()

local fake = require("fake_adapter")
package.loaded["platform.adapter"] = fake.adapter   -- preempt the seam

-- Pin the fake clock to a deterministic mid-day instant: the suite advances time
-- via fake.clockOffset, and a real near-midnight wall clock would otherwise cross
-- a day boundary mid-test (day-rollover resets fire). Re-applied by freshWorld().
local function pinClock()
    local pin = os.date("*t") --[[@as osdateparam]]
    pin.hour, pin.min, pin.sec = 10, 0, 0
    fake.clockOffset = os.time(pin) - os.time()
end
pinClock()

local registry = require("platform.registry")
local manifest = require("platform.manifest")
local triggers = require("platform.triggers")
local W        = require("platform.windows")
local rules    = require("platform.rules")
local i18n     = require("platform.i18n")

local M = {}
local passed = 0

---The scoped test handle passed to every case's `run(t)` and sourced by the
---monolith. Carries the shared requires, the assert, and the pure helpers.
---@class Harness
---@field fake table            the fake adapter (scenario state + observation queues)
---@field registry table        the real platform registry
---@field manifest table        platform.manifest
---@field triggers table        platform.triggers
---@field W table               platform.windows
---@field AC string[]           the { cmd, alt, ctrl } hyper mod set
---@field ok fun(cond:any, msg:string)                                    the universal assert (drives `passed`)
---@field rejects fun(m:table, why:string)                                assert manifest.validate rejects `m`
---@field lastFrame fun():{x:number,y:number,w:number,h:number}?          the most-recently recorded window frame
---@field frameEq fun(nf:table, x:number, y:number, w:number, h:number, msg:string)  assert a frame equals x/y/w/h
---@field minutesFromNow fun(min:number):string                          "%H:%M" `min` minutes past the fake clock
local t = {
    fake = fake, registry = registry, manifest = manifest, triggers = triggers, W = W,
    AC = { "cmd", "alt", "ctrl" },
}

function t.ok(cond, msg)
    if not cond then error("FAIL: " .. msg, 2) end
    passed = passed + 1
end

function t.rejects(m, why)
    t.ok(pcall(manifest.validate, m) == false, "manifest rejected: " .. why)
end

function t.lastFrame() return fake.windowFrames[#fake.windowFrames] end

function t.frameEq(nf, x, y, w, h, msg)
    t.ok(nf.x == x and nf.y == y and nf.w == w and nf.h == h,
        msg .. " (got " .. nf.x .. "," .. nf.y .. "," .. nf.w .. "," .. nf.h .. ")")
end

function t.minutesFromNow(min)
    return os.date("%H:%M", fake.now() + min * 60) --[[@as string]]
end

M.t = t

--- Per-case pristine world (RUN_LUA_SPLIT_SPEC R4+R5). ORDER MATTERS: tear the
--- platform down through the real stop path FIRST -- BOTH registry.reset() and
--- rules.load({}) free native handles through the fake (feature stop() and rules'
--- watcher stop()) -- THEN wipe the fake to pristine, THEN re-pin the clock.
--- Wiping the fake before either teardown zeroes fake.liveHandles, and the
--- teardown then decrements it NEGATIVE (a mis-attributed tripwire failure).
function M.freshWorld()
    registry.reset()   -- platform teardown, phase 1: unbind features through stop()
    rules.load({})     -- platform teardown, phase 1: stop every live rule
    fake.resetWorld()  -- THEN wipe the fake to pristine (zeroes liveHandles + registries)
    pinClock()         -- re-pin the deterministic clock resetWorld cleared
    -- i18n is a process-global singleton (module-level `locale`, catalog caches) that
    -- freshWorld would otherwise miss: a case switching locale (describe_localization)
    -- must not leak zh-Hans into the next case. configure(en) is its canonical reset.
    i18n.configure({ locale = "en" })
end

--- The single assertion total, preserved verbatim from the monolith's final line.
function M.report()
    print("OK -- " .. passed .. " assertions passed (" .. _VERSION .. ")")
end

--- Discover hermetic case files under `dir` (per-feature) and `dir/_integration`
--- (cross-catalog), each a module returning { id, run = function(t) end, tags? }.
--- `argv` is the script's `arg` table: a bare `<id>` narrows the CASES loop to
--- that one case; `--shuffle` randomizes their order (the order-independence
--- self-check, R8). Default order is sorted by id for stable output; per-feature
--- cases first, then _integration (readability only -- every case is hermetic
--- regardless of order). NOTE (Phase 1): the legacy monolith in run.lua still runs
--- first regardless of `<id>` -- full R10 "run one case, skip the rest" arrives
--- when the monolith is retired (Phase 5).
---@param dir string
---@param argv string[]?
---@return { id:string, run:fun(t:Harness), tags:string[]? }[]
function M.discover(dir, argv)
    argv = argv or {}
    local only, shuffle = nil, false
    for _, a in ipairs(argv) do
        if a == "--shuffle" then shuffle = true
        elseif a:sub(1, 2) ~= "--" then only = a end
    end
    -- io.popen disk scan (the mechanism T25g uses, proven on both engines) -- NOT
    -- registry.discover, which under the fake returns a preset featureNames list.
    local function scan(d, tag)
        local out = {}
        local pipe = io.popen('ls "' .. d .. '"/*.lua 2>/dev/null')
        if not pipe then return out end
        for path in pipe:lines() do
            local case = dofile(path)
            -- Fail LOUDLY on a malformed case -- a silently-dropped file is lost
            -- coverage a regression suite must never hide (a test that never runs
            -- can never fail, so the gap is invisible).
            if type(case) ~= "table" or not case.id or not case.run then
                error(path .. ": a case file must `return { id = ..., run = function(t) ... end }`")
            end
            if tag and not case.tags then case.tags = { tag } end
            out[#out + 1] = case
        end
        pipe:close()
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end
    local cases = scan(dir)
    for _, c in ipairs(scan(dir .. "/_integration", "integration")) do cases[#cases + 1] = c end
    if only then
        local filtered = {}
        for _, c in ipairs(cases) do if c.id == only then filtered[#filtered + 1] = c end end
        cases = filtered
    end
    if shuffle then
        math.randomseed()   -- 5.4/5.5 auto-entropy: a distinct order even on sub-second reruns
        for i = #cases, 2, -1 do
            local j = math.random(i)
            cases[i], cases[j] = cases[j], cases[i]
        end
    end
    return cases
end

return M
