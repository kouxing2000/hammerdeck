-- features/window_snap
--
-- Arrange the focused window (ported from the author's prior Hammerspoon
-- config): snap to screen halves, toggle
-- maximize <-> centered 75%, throw to the next/previous screen with
-- proportional rescaling + the mouse pointer carried along, and swap ALL
-- windows between the two displays.
--
-- MULTI-ACTION feature: each arrangement is its own independently rebindable
-- action (the donor's seven hotkeys). Fullscreen windows are taken out of
-- fullscreen first, then the arrangement retries (donor behavior).
--
-- Needs the Accessibility permission (focused-window frame surface); without
-- it every action alerts the onboarding message.

local W = require("platform.windows")
local json = require("platform.json")

local RETRY_SECONDS = 0.5   -- fullscreen exit settle time before retrying
local TOGGLE_SCALE  = 0.75  -- the "smaller" size of the maximize toggle

-- Build the helpers around a ctx once per enablement.
---@param ctx Ctx
local function arranger(ctx)
    local a = {}

    -- The focused window, or nil after alerting (the per-action guard).
    local function focused()
        return W.focusedOrAlert(ctx, "Window Arrange")
    end

    -- Exit fullscreen and re-run `retry` after a beat (donor behavior).
    local function unfullscreenThen(retry)
        ctx.window.setFullscreen(false)
        ctx.afterSeconds(RETRY_SECONDS, retry)
    end

    -- Snap to a screen-ratio rect: x/y position, w/h size (donor's
    -- positionWindow).
    function a.snap(xR, yR, wR, hR)
        local f = focused()
        if not f then return end
        ctx.window.setFrame(W.rectFromRatios(f.screen, xR, yR, wR, hR))
    end

    -- Maximized (full width or height) -> centered 75%; else maximize.
    function a.toggleMax()
        local f = focused()
        if not f then return end
        if f.fullscreen then return unfullscreenThen(a.toggleMax) end
        local s = f.screen
        if f.w == s.w or f.h == s.h then
            local m = (1 - TOGGLE_SCALE) / 2
            ctx.window.setFrame(
                W.rectFromRatios(s, m, m, TOGGLE_SCALE, TOGGLE_SCALE))
        else
            ctx.window.setFrame(W.rectFromRatios(s, 0, 0, 1, 1))
        end
    end

    -- Move to the adjacent screen (by index), rescaling the frame with the
    -- shared least-distortion geometry (windows.moveToScreen). The pointer is
    -- carried over at the same relative spot and flashed.
    ---@param dir ScreenDir
    function a.moveScreen(dir)
        local f = focused()
        if not f then return end
        if f.fullscreen then
            return unfullscreenThen(function() a.moveScreen(dir) end)
        end
        local screens = ctx.screen.frames()
        if #screens < 2 then
            ctx.alert(ctx.t("alert.oneScreen", "Only one screen"))
            return
        end
        -- "next/prev" follow the PHYSICAL display arrangement (left-to-right),
        -- not NSScreen.screens' registration order (see windows.adjacentScreen).
        local s, t = f.screen, W.adjacentScreen(screens, f.screenIndex, dir)
        if not t then return end   -- unreachable (#screens >= 2); keeps types exact
        local nf = W.moveToScreen(f, s, t)

        -- Capture the pointer's spot INSIDE the window (as a ratio) BEFORE moving,
        -- then map it onto the NEW frame so the cursor tracks the WINDOW across the
        -- hop. Two fixes over the old carry: (1) window-relative, not the raw
        -- SCREEN offset -- moveToScreen rescales the window, so a screen offset
        -- drifted the pointer clean off it; (2) read BEFORE ctx.window.setFrame,
        -- which may ITSELF carry the pointer (the pointer_follows_window policy in
        -- window_ops) -- reading after compounded the two carries and flung the
        -- pointer away. Ratio clamped so a pointer outside the window lands on its
        -- edge, not off-screen.
        local m = ctx.mouse.position()
        local rx = (f.w > 0) and math.min(math.max((m.x - f.x) / f.w, 0), 1) or 0.5
        local ry = (f.h > 0) and math.min(math.max((m.y - f.y) / f.h, 0), 1) or 0.5

        ctx.window.setFrame(nf)   -- least-distortion rescale + clamp (windows.lua)
        ctx.mouse.setPosition(nf.x + rx * nf.w, nf.y + ry * nf.h)
        ctx.mouse.locate(2)
    end

    -- Swap EVERY window between two displays: all windows on one move to the
    -- other and vice versa, each rescaled with the same least-distortion geometry
    -- as the single-window throw (windows.moveToScreen). Distinct from moveScreen:
    -- it operates on the whole window LIST, not just the focused one.
    --
    -- Uses the batch placement primitive (ctx.window.setFrameFor) on purpose: it
    -- sets each frame WITHOUT raising or activating the window and WITHOUT moving
    -- the pointer -- a multi-window layout must never fight z-order or yank the
    -- cursor (the Z-order hard constraint; see CLAUDE.md -- window_deck and the
    -- rules-engine layout effect follow the same rule). Minimized/fullscreen
    -- windows, and windows on any OTHER display, are left untouched.
    local function swapBetween(frames, iA, iB)
        local A, B = frames[iA], frames[iB]
        -- Guard the indices against the CURRENT frames: the picker is async, so a
        -- display may have been unplugged/rearranged while it was open, leaving a
        -- picked index dangling. Abort rather than index a nil screen rect.
        if not A or not B then return end
        -- One snapshot: ids stay valid (no re-list mid-batch) and each window's
        -- target is computed from its captured frame BEFORE its own move.
        local wins = ctx.window.list()
        local moved = 0
        for _, w in ipairs(wins) do
            if not (w.minimized or w.fullscreen) then
                -- Containing, not At: this asks which display the window IS on,
                -- and screenIndexAt's `or 1` answered "display 1" for a window
                -- whose centre is on no display at all -- so an off-screen
                -- window was dragged onto display 1 and counted as swapped.
                -- nil matches neither side, which leaves it where it is.
                local idx = W.screenIndexContaining(frames, w.x + w.w / 2, w.y + w.h / 2)
                local src, dst
                if idx == iA then src, dst = A, B
                elseif idx == iB then src, dst = B, A end
                if src then
                    ctx.window.setFrameFor(w.id, W.moveToScreen(w, src, dst))
                    moved = moved + 1
                end
            end
        end
        ctx.log(string.format(
            "window_snap: swap displays -- moved %d window(s) between %s and %s",
            moved, A.name or ("#" .. iA), B.name or ("#" .. iB)))
    end

    -- Per-display window counts (skipping minimized/fullscreen, matching what the
    -- swap will actually move) so the picker can show "N windows" on each display.
    local function displaysWithCounts(frames)
        local counts = {}
        for i = 1, #frames do counts[i] = 0 end
        for _, w in ipairs(ctx.window.list()) do
            if not (w.minimized or w.fullscreen) then
                -- Same membership question as swapBetween, and the count has to
                -- agree with what the swap will move: the `or 1` fallback
                -- inflated display 1's "N windows" with every off-screen window.
                local idx = W.screenIndexContaining(frames, w.x + w.w / 2, w.y + w.h / 2)
                if idx then counts[idx] = (counts[idx] or 0) + 1 end
            end
        end
        local out = {}
        for i, s in ipairs(frames) do
            out[i] = { x = s.x, y = s.y, w = s.w, h = s.h, name = s.name, windows = counts[i] }
        end
        return out
    end

    -- The spatial display picker for the 3+-display case: the user picks the TWO
    -- displays to swap off a map. The active display is a DEFAULT only (passed
    -- LAST in `preselect` so it stays selected when the user clicks a new partner);
    -- either side is freely changeable -- there is no locked "current". One-shot +
    -- scope-tracked, so nothing to memoize or tear down here. cb gets {a, b}.
    local function pickPair(frames, activeIdx, cb)
        -- default the other side to the display spatially next to the active one
        local _, nextIdx = W.adjacentScreen(frames, activeIdx, W.DIR.NEXT)
        local other = (nextIdx and nextIdx ~= activeIdx) and nextIdx or nil
        if not other then
            for i = 1, #frames do if i ~= activeIdx then other = i; break end end
        end
        ctx.screen.pickDisplay {
            displays    = displaysWithCounts(frames),
            preselect   = other and { other, activeIdx } or { activeIdx },
            selectCount = 2,
            title       = ctx.t("swap.pickTitle", "Swap which two displays?"),
            prompt      = ctx.t("swap.pickPrompt",
                "Pick the two displays to swap. Your current one is selected by default -- change either."),
            confirmVerb = ctx.t("swap.pickVerb", "Swap"),
            onPick      = function(pair)
                if pair and pair[1] and pair[2] then cb(pair[1], pair[2]) end
            end,
        }
    end

    -- Swap the windows of the ACTIVE display (the one the user is on) with those
    -- of another. Per the design: the active display is ALWAYS one side of the
    -- swap. With exactly two displays there is nothing to choose, so it swaps
    -- immediately; with three or more it first asks which OTHER display to use.
    function a.swapScreens()
        local frames = ctx.screen.frames()
        if #frames < 2 then
            ctx.alert(ctx.t("alert.oneScreen", "Only one screen"))
            return
        end
        -- Needs Accessibility to read/move windows. Onboard like the other actions
        -- (which route through W.focusedOrAlert) instead of silently no-op'ing --
        -- without the grant ctx.window.list() is empty, so this would move nothing
        -- and (on 3+ displays) open a picker showing "0 windows" everywhere.
        if not ctx.axTrusted() then
            ctx.axPrompt()
            ctx.alert(
                ctx.t("window.axRequired",
                    "%1$s needs the Accessibility permission -- grant %2$s in System Settings, then try again", "Window Arrange", ctx.appName))
            return
        end
        -- The active display: the focused window's screen, else the pointer's,
        -- else the main screen (screenIndexAt defaults to 1 off every screen).
        local activeIdx
        local wf = ctx.window.frame()
        if wf and wf.screenIndex then
            activeIdx = wf.screenIndex
        else
            local m = ctx.mouse.position()
            activeIdx = W.screenIndexAt(frames, m.x, m.y)
        end

        local others = {}
        for i = 1, #frames do
            if i ~= activeIdx then others[#others + 1] = i end
        end

        if #others == 1 then
            swapBetween(frames, activeIdx, others[1])
        else
            pickPair(frames, activeIdx, function(ia, ib)
                -- Re-fetch the screen rects: the picker is async, so the display
                -- arrangement may have changed while it was open. swapBetween
                -- bounds-guards the picked indices against the current frames.
                swapBetween(ctx.screen.frames(), ia, ib)
            end)
        end
    end

    return a
end

-- One arranger per enablement (ctx changes on re-enable; ctx.perEnable memoizes).
---@param ctx Ctx
local function with(ctx)
    return ctx.perEnable(arranger)
end

-- ---------------------------------------------------------------------------
-- User-defined placement presets. Each is a saved rectangle {id,name,x,y,w,h}
-- (x/y/w/h are screen fractions in [0,1]) designed in the inline Settings editor
-- (the `placementList` option). The registry turns each stored preset into its
-- OWN rebindable action ("preset_<uuid>") via the dynamicActions hook below, so a
-- user can bind a custom placement to a shortcut -- the one-key replacement for
-- stepping a window through the grid by hand. All self-contained: presets live in
-- window_snap's own option namespace and apply with the SAME rectFromRatios call
-- the built-in half-snaps use. No dependency on any other feature.
-- ---------------------------------------------------------------------------

---@class SnapPreset
---@field id string     stable UUID (the action key -- survives rename/reorder)
---@field name string
---@field x number
---@field y number
---@field w number
---@field h number

local function clamp01(v) return math.max(0, math.min(1, v)) end

-- Decode the stored presets option (a JSON array string) into a validated list.
-- Tolerant by design: a nil / blank / corrupt / partial value yields {} and any
-- malformed or duplicate-id entry is dropped, so a bad setting can NEVER break the
-- feature -- the built-in snaps still bind. Pure (platform.json is a leaf util).
---@param raw any
---@return SnapPreset[]
local function decodePresets(raw)
    if type(raw) ~= "string" or raw:match("^%s*$") then return {} end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" then return {} end
    local out, seen = {}, {}
    for _, p in ipairs(data) do
        if type(p) == "table" and type(p.id) == "string" and p.id ~= "" and not seen[p.id]
            and type(p.x) == "number" and type(p.y) == "number"
            and type(p.w) == "number" and type(p.h) == "number" then
            -- Clamp to on-screen fractions so even a hand-edited / corrupt-but-typed
            -- setting can only ever produce a rectangle INSIDE the display (the
            -- Swift editor already constrains to [0,1]; this guards the seam).
            local x, y = clamp01(p.x), clamp01(p.y)
            local w = math.min(clamp01(p.w), 1 - x)
            local h = math.min(clamp01(p.h), 1 - y)
            if w > 0 and h > 0 then
                seen[p.id] = true
                out[#out + 1] = {
                    id   = p.id,
                    name = (type(p.name) == "string" and p.name ~= "") and p.name or "Placement",
                    x = x, y = y, w = w, h = h,
                }
            end
        end
    end
    return out
end

local MODS = { "cmd", "alt", "ctrl" }

return {
    api         = 1,
    id          = "window_snap",

    options = {
        -- The inline placement designer: a variable-length list of rectangles,
        -- edited in Settings (PlacementListEditor -- click two corners on a grid).
        -- Stored as a JSON-array string in window_snap's OWN option namespace; the
        -- registry turns each entry into a bindable action via the dynamicActions
        -- hook below.
        -- The saved list starts EMPTY -- your placements only. Common arrangements
        -- (thirds, quarters, center, ...) are a QUICK-ADD library in the editor, NOT
        -- seeded data, so there is nothing to mask or restore. Adding one drops a
        -- normal placement into the list; each becomes a "preset_<id>" action via
        -- dynamicActions. Not collapsible: it is the feature's primary content.
        { key = "presets", type = "placementList", default = "",
          label = "Saved placements",
          hint = "Quick-add a common arrangement or design your own, then bind it to a shortcut." },
    },

    -- Turn each stored preset into its own independently-rebindable action.
    -- Invoked by the REGISTRY at register time with a scoped option reader, so the
    -- feature never touches the adapter seam. Action ids are stable
    -- ("preset_<uuid>") so a rename or reorder keeps the user's bound shortcut.
    -- Presets ship WITHOUT a defaultTrigger -- dormant until the user binds one,
    -- like the swap action (no uninvited hotkey grabs).
    ---@param read fun(key: string): any
    dynamicActions = function(read)
        local out = {}
        for _, p in ipairs(decodePresets(read("presets"))) do
            out[#out + 1] = {
                id    = "preset_" .. p.id,
                label = p.name,
                description = "Move the focused window to your saved \"" .. p.name .. "\" placement.",
                run   = function(ctx) with(ctx).snap(p.x, p.y, p.w, p.h) end,
            }
        end
        return out
    end,

    actions = {
        { id = "left", label = "Left half", icon = "rectangle.lefthalf.filled",
          description = "Move the focused window to the left half of the screen.",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "left" },
          mnemonic = "Hyper+← — the arrow points to the edge",
          ---@param ctx Ctx
          run = function(ctx) with(ctx).snap(0, 0, 0.5, 1) end },
        { id = "right", label = "Right half", icon = "rectangle.righthalf.filled",
          description = "Move the focused window to the right half of the screen.",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "right" },
          mnemonic = "Hyper+→ — the arrow points to the edge",
          ---@param ctx Ctx
          run = function(ctx) with(ctx).snap(0.5, 0, 0.5, 1) end },
        { id = "top", label = "Top half", icon = "rectangle.tophalf.filled",
          description = "Move the focused window to the top half of the screen.",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "up" },
          mnemonic = "Hyper+↑ — the arrow points to the edge",
          ---@param ctx Ctx
          run = function(ctx) with(ctx).snap(0, 0, 1, 0.5) end },
        { id = "bottom", label = "Bottom half", icon = "rectangle.bottomhalf.filled",
          description = "Move the focused window to the bottom half of the screen.",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "down" },
          mnemonic = "Hyper+↓ — the arrow points to the edge",
          ---@param ctx Ctx
          run = function(ctx) with(ctx).snap(0, 0.5, 1, 0.5) end },

        -- The thirds (and quarters, center, ...) are no longer hardcoded here: they
        -- live as a QUICK-ADD recipe library in the placement editor. Add one and it
        -- becomes your own "preset_<id>" placement (editable, bindable) via
        -- dynamicActions -- the columns-of-three idiom the halves don't cover, self-served.

        { id = "toggle_max", label = "Maximize / 75%", icon = "arrow.up.left.and.arrow.down.right",
          description = "Toggle the focused window between maximized and 75% centered.",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "return" },
          mnemonic = "Hyper+Return — Return = fill the screen",
          ---@param ctx Ctx
          run = function(ctx) with(ctx).toggleMax() end },
        { id = "screen_next", label = "To next screen", icon = "arrow.right.to.line",
          description = "Throw the focused window to the next screen, rescaling it "
              .. "proportionally and carrying the pointer along.",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "]" },
          mnemonic = "Hyper+] — ] pushes forward to the next screen",
          ---@param ctx Ctx
          run = function(ctx) with(ctx).moveScreen(W.DIR.NEXT) end },
        { id = "screen_prev", label = "To previous screen", icon = "arrow.left.to.line",
          description = "Throw the focused window to the previous screen, rescaling "
              .. "it proportionally and carrying the pointer along.",
          defaultTrigger = { type = "hotkey", mods = MODS, key = "[" },
          mnemonic = "Hyper+[ — [ pushes back to the previous screen",
          ---@param ctx Ctx
          run = function(ctx) with(ctx).moveScreen(W.DIR.PREV) end },

        -- Swap the whole layout across the two displays. No default trigger (like
        -- the thirds): a swap-all is a deliberate, occasional action, not worth
        -- grabbing another global hotkey for uninvited -- fire it from the menubar
        -- or bind any key/chord in Settings.
        { id = "swap_screens", label = "Swap windows between displays", icon = "arrow.left.arrow.right",
          description = "Swap the windows of the display you are on with another "
              .. "display's -- everything on each moves to the other, rescaled "
              .. "proportionally. On three or more displays it first asks which "
              .. "one. Minimized and fullscreen windows stay put.",
          ---@param ctx Ctx
          run = function(ctx) with(ctx).swapScreens() end },
    },
}
