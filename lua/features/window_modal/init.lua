-- features/window_modal
--
-- "Window Mode": a modal keyboard layer for window manipulation (ported from
-- myHammerSpoon modules/window/winWinModal.lua + the WinWin/ModalMgr spoons).
-- Enter the mode, then bare keys arrange the focused window until Escape:
--
--   W A S D        step-move (screen/N per step)
--   H J K L        halves (left/down/up/right)
--   shift+H J K L  step-resize (narrower/taller/shorter/wider)
--   Y U I O        corners (NW/SW/SE/NE quadrants)
--   F              maximize        C   center (size kept)
--   = / -          expand / shrink (one step on every side, center fixed)
--   arrows         move to the screen in that direction   space  next screen
--   [ / ]          undo / redo     Esc  exit
--
-- Departures from the donor: redo actually works (the donor bound a
-- WinWin:redo() that does not exist in the spoon); undo is a proper stack
-- (the donor replayed every historical frame of the window in order); the
-- donor's separate alt+G "center cursor on window" is the second action.
--
-- Needs Accessibility (the focused-window frame surface).

local HISTORY_MAX = 50

local function arrangerFor(ctx)
    local st = { mode = nil, undoStack = {}, redoStack = {} }

    local function focused()
        local f = ctx.focusedWindowFrame()
        if f then return f end
        if not ctx.axTrusted() then
            ctx.axPrompt()
            ctx.alert("Window Mode needs the Accessibility permission")
        else
            ctx.alert("No focused window")
        end
        return nil
    end

    local function steps(f)
        local n = ctx.opt("stepParts")
        return f.screen.w / n, f.screen.h / n
    end

    local function setFrame(nf)
        ctx.setFocusedWindowFrame(nf)
    end

    -- Stash the pre-op frame (cap like the donor); a new op clears redo.
    local function stash(f)
        local u = st.undoStack
        u[#u + 1] = { x = f.x, y = f.y, w = f.w, h = f.h }
        if #u > HISTORY_MAX then table.remove(u, 1) end
        st.redoStack = {}
    end

    -- Run `op(f, stepw, steph)` -> new frame, on the focused window, with the
    -- donor's fullscreen guard and history stash.
    local function apply(op)
        local f = focused()
        if not f then return end
        if f.fullscreen then
            -- Exit fullscreen; the next key press applies normally.
            ctx.setFocusedWindowFullscreen(false)
            return
        end
        local stepw, steph = steps(f)
        local nf = op(f, stepw, steph)
        if nf then
            stash(f)
            setFrame(nf)
        end
    end

    local function undo()
        local f = focused()
        if not f then return end
        local prev = table.remove(st.undoStack)
        if not prev then return end
        local r = st.redoStack
        r[#r + 1] = { x = f.x, y = f.y, w = f.w, h = f.h }
        setFrame(prev)
    end

    local function redo()
        local f = focused()
        if not f then return end
        local nxt = table.remove(st.redoStack)
        if not nxt then return end
        local u = st.undoStack
        u[#u + 1] = { x = f.x, y = f.y, w = f.w, h = f.h }
        setFrame(nxt)
    end

    -- Move to another screen: size kept, position scaled per axis (clamped;
    -- shrunk only if larger than the target). dir = left|right|up|down|next.
    local function moveScreen(dir)
        apply(function(f)
            local screens = ctx.screenFrames()
            if #screens < 2 then
                ctx.alert("Only one screen")
                return nil
            end
            local s = f.screen
            local target
            if dir == "next" then
                target = screens[(f.screenIndex % #screens) + 1]
            else
                -- The nearest screen whose center lies in that direction.
                local cx, cy = s.x + s.w / 2, s.y + s.h / 2
                local best
                for i, t in ipairs(screens) do
                    if i ~= f.screenIndex then
                        local tx, ty = t.x + t.w / 2, t.y + t.h / 2
                        local dx, dy = tx - cx, ty - cy
                        local along
                        if dir == "left" then along = -dx
                        elseif dir == "right" then along = dx
                        elseif dir == "up" then along = -dy
                        else along = dy end
                        if along > 0 and (not best or along < best.along) then
                            best = { t = t, along = along }
                        end
                    end
                end
                if not best then
                    ctx.alert("No screen " .. dir)
                    return nil
                end
                target = best.t
            end
            local nf = {
                w = math.min(f.w, target.w), h = math.min(f.h, target.h),
                x = target.x + (f.x - s.x) * (target.w / s.w),
                y = target.y + (f.y - s.y) * (target.h / s.h),
            }
            if nf.x + nf.w > target.x + target.w then nf.x = target.x + target.w - nf.w end
            if nf.y + nf.h > target.y + target.h then nf.y = target.y + target.h - nf.h end
            return nf
        end)
    end

    local function snap(xR, yR, wR, hR)
        apply(function(f)
            local s = f.screen
            return { x = s.x + s.w * xR, y = s.y + s.h * yR,
                     w = s.w * wR, h = s.h * hR }
        end)
    end

    local function move(dx, dy)
        apply(function(f, stepw, steph)
            return { x = f.x + dx * stepw, y = f.y + dy * steph, w = f.w, h = f.h }
        end)
    end

    local function resize(dw, dh)
        apply(function(f, stepw, steph)
            return { x = f.x, y = f.y,
                     w = math.max(f.w + dw * stepw, stepw),
                     h = math.max(f.h + dh * steph, steph) }
        end)
    end

    -- expand/shrink: one step on EVERY side, center fixed (WinWin).
    local function inflate(sign)
        apply(function(f, stepw, steph)
            local w = math.max(f.w + sign * 2 * stepw, stepw)
            local h = math.max(f.h + sign * 2 * steph, steph)
            return { x = f.x - sign * stepw, y = f.y - sign * steph, w = w, h = h }
        end)
    end

    local function center()
        apply(function(f)
            local s = f.screen
            return { x = s.x + (s.w - f.w) / 2, y = s.y + (s.h - f.h) / 2,
                     w = f.w, h = f.h }
        end)
    end

    function st.toggleMode()
        if st.mode and st.mode.isActive() then
            st.mode.stop()
            st.mode = nil
            return
        end
        st.mode = ctx.modal {
            name = "Window Mode",
            hint = "WASD move · HJKL halves · ⇧HJKL resize · YUIO corners · "
                .. "F max · C center · -/= shrink/expand · arrows screens · [ ] undo/redo",
            onExit = function() st.mode = nil end,
            -- repeats=true on the INCREMENTAL keys (nudge/resize/inflate) so
            -- holding one keeps stepping; snaps/corners/screen-moves are
            -- absolute, so repeating them is a no-op and they stay single-shot.
            bindings = {
                { key = "a", repeats = true, fn = function() move(-1, 0) end },
                { key = "d", repeats = true, fn = function() move(1, 0) end },
                { key = "w", repeats = true, fn = function() move(0, -1) end },
                { key = "s", repeats = true, fn = function() move(0, 1) end },
                { key = "h", fn = function() snap(0, 0, 0.5, 1) end },
                { key = "l", fn = function() snap(0.5, 0, 0.5, 1) end },
                { key = "k", fn = function() snap(0, 0, 1, 0.5) end },
                { key = "j", fn = function() snap(0, 0.5, 1, 0.5) end },
                { mods = { "shift" }, key = "h", repeats = true, fn = function() resize(-1, 0) end },
                { mods = { "shift" }, key = "l", repeats = true, fn = function() resize(1, 0) end },
                { mods = { "shift" }, key = "k", repeats = true, fn = function() resize(0, -1) end },
                { mods = { "shift" }, key = "j", repeats = true, fn = function() resize(0, 1) end },
                { key = "y", fn = function() snap(0, 0, 0.5, 0.5) end },
                { key = "o", fn = function() snap(0.5, 0, 0.5, 0.5) end },
                { key = "u", fn = function() snap(0, 0.5, 0.5, 0.5) end },
                { key = "i", fn = function() snap(0.5, 0.5, 0.5, 0.5) end },
                { key = "f", fn = function() snap(0, 0, 1, 1) end },
                { key = "c", fn = center },
                { key = "=", repeats = true, fn = function() inflate(1) end },
                { key = "-", repeats = true, fn = function() inflate(-1) end },
                { key = "left", fn = function() moveScreen("left") end },
                { key = "right", fn = function() moveScreen("right") end },
                { key = "up", fn = function() moveScreen("up") end },
                { key = "down", fn = function() moveScreen("down") end },
                { key = "space", fn = function() moveScreen("next") end },
                { key = "[", fn = undo },
                { key = "]", fn = redo },
            },
        }
    end

    function st.centerCursor()
        local f = ctx.focusedWindowFrame()
        if f then
            ctx.setMousePosition(f.x + f.w / 2, f.y + f.h / 2)
        else
            local s = ctx.screenFrames()[1]
            if s then ctx.setMousePosition(s.x + s.w / 2, s.y + s.h / 2) end
        end
        ctx.locateMouse(1)
    end

    return st
end

-- One arranger per enablement.
local cached = nil
local function with(ctx)
    if not cached or cached.ctx ~= ctx then
        cached = { ctx = ctx, st = arrangerFor(ctx) }
    end
    return cached.st
end

return {
    api         = 1,
    id          = "window_modal",
    name        = "Window Mode",
    description = "A modal keyboard layer for window arranging: enter the "
        .. "mode, tap keys to move/resize/snap until Escape.",
    version     = "1.0.0",
    category    = "productivity",

    options = {
        { key = "stepParts", type = "int", default = 30, min = 10, max = 60,
          label = "Steps per screen (move/resize granularity)" },
    },

    actions = {
        { id = "enter", label = "Enter / exit window mode",
          defaultTrigger = { type = "hotkey", mods = { "ctrl", "cmd" }, key = "2" },
          run = function(ctx) with(ctx).toggleMode() end },
        { id = "center_cursor", label = "Center pointer on window",
          defaultTrigger = { type = "hotkey", mods = { "alt" }, key = "g" },
          run = function(ctx) with(ctx).centerCursor() end },
    },
}
