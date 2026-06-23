-- features/insert_datetime
--
-- Type the current date/time into the focused field (ported from the
-- myHammerSpoon "insert data time" binding, cmd+alt+ctrl+D). Pure Lua over
-- ctx -- no native surface of its own; ctx.typeText synthesizes the keystrokes.
--
-- The format is user-selectable: pick one of the presets, or choose "Custom"
-- and enter any strftime pattern in the Custom format field. The original HS
-- binding hardcoded "%m/%d/%Y %I:%M:%S %p" -- that is the default preset here.
--
-- Time comes from ctx.now() (the controlled clock tests can drive); os.date is
-- used only to FORMAT that instant, never to read the wall clock directly.

-- Preset strftime patterns. The enum stores the pattern itself as the value
-- (so the action can use it verbatim) except the "custom" sentinel, which means
-- "read the customFormat option instead". Labels carry a representative example
-- so the picker is self-explanatory without a live preview.
local PRESETS = {
    values = {
        "%m/%d/%Y %I:%M:%S %p",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d",
        "%H:%M:%S",
        "%I:%M %p",
        "%A, %B %d, %Y",
        "%d/%m/%Y",
        "custom",
    },
    labels = {
        "US 12-hour  (06/23/2026 03:04:05 PM)",
        "ISO 24-hour  (2026-06-23 15:04:05)",
        "ISO date  (2026-06-23)",
        "Time 24-hour  (15:04:05)",
        "Time 12-hour  (03:04 PM)",
        "Long date  (Monday, June 23, 2026)",
        "EU date  (23/06/2026)",
        "Custom (use the field below)",
    },
}

-- Resolve the live strftime pattern: the chosen preset, or the custom field when
-- "Custom" is selected. Returns nil when custom is selected but empty.
local function resolveFormat(ctx)
    local fmt = ctx.opt("format")
    if fmt == "custom" then
        local custom = ctx.opt("customFormat")
        if not custom or custom == "" then return nil end
        return custom
    end
    return fmt
end

-- Format `when` with strftime `fmt`, guarding the TWO ways os.date can fail:
--   * an invalid specifier (e.g. "%Q" or a lone "%") RAISES in Lua 5.4, so we
--     pcall it -- without this an action would crash on a bad custom pattern;
--   * "*t"/"!*t" return a TABLE we cannot type.
-- Returns the string, or (nil, human-readable reason). This is the single
-- validator both the action and the Settings "Preview" button go through, so a
-- preview can never disagree with what typing actually produces.
local function formatNow(fmt, when)
    local ok, res = pcall(os.date, fmt, when)
    if not ok then
        -- Strip a leading "file:line: " prefix if pcall added one, then prefer
        -- the parenthetical reason (e.g. "invalid conversion specifier '%Q'").
        local msg = tostring(res):gsub("^.-:%d+: ", "")
        local detail = msg:match("%((.-)%)") or msg
        return nil, "Invalid format -- " .. detail
    end
    if type(res) ~= "string" then
        return nil, "That format produces a table, not text (avoid *t)"
    end
    return res
end

local function insert(ctx)
    local fmt = resolveFormat(ctx)
    if not fmt then
        ctx.notify("Insert Date/Time",
            "Pick a preset, or enter a Custom format in Settings")
        return
    end
    local text, err = formatNow(fmt, ctx.now())
    if not text then
        ctx.notify("Insert Date/Time", err)
        return
    end
    ctx.typeText(text)
    return text   -- returned for tests; ignored by the trigger path
end

return {
    api         = 1,
    id          = "insert_datetime",
    name        = "Insert Date/Time",
    description = "Type the current date and time into the focused field, "
        .. "in a format you choose (or a custom strftime pattern).",
    version     = "1.0.0",
    category    = "productivity",

    options = {
        { key = "format", type = "enum", default = "%m/%d/%Y %I:%M:%S %p",
          values = PRESETS.values, labels = PRESETS.labels,
          label = "Format" },
        { key = "customFormat", type = "string", default = "",
          label = "Custom format (strftime)", actionLabel = "Preview",
          hint = "Used when Format is Custom. e.g. %Y/%m/%d %H:%M -- see strftime." },
    },

    -- Settings "Preview" button on the Custom format field: the validator. It
    -- formats the current time with the entered pattern via the SAME formatNow
    -- path the action uses, so it either shows exactly what typing would produce
    -- or the reason the pattern is invalid -- caught here instead of at type time.
    optionActions = {
        customFormat = function(ctx)
            local fmt = ctx.opt("customFormat")
            if not fmt or fmt == "" then
                ctx.alert("Enter a custom format first")
                return
            end
            local text, err = formatNow(fmt, ctx.now())
            ctx.alert(text and ("Preview:  " .. text) or err)
        end,
    },

    defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "d" },
    mnemonic = "D for Date",
    action = insert,
}
