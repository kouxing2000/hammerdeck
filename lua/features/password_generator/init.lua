-- features/password_generator
--
-- Generate a strong random password and put it on the clipboard
-- (ported from the PasswordGenerator spoon). Pure Lua over ctx -- no native.
--
-- Charset is assembled from the enabled categories; the result is GUARANTEED
-- to contain at least one character from each enabled category (a common
-- password-policy requirement) when the length allows, then filled and shuffled.
--
-- Randomness: ctx.randomInt is a CRYPTOGRAPHICALLY SECURE uniform draw
-- (SecRandomCopyBytes in the host, behind the seam) -- never Lua's math.random,
-- which is a predictable PRNG and wrong for generating secrets.

local LOWER  = "abcdefghijkmnopqrstuvwxyz"          -- no l
local UPPER  = "ABCDEFGHJKLMNPQRSTUVWXYZ"           -- no I, O
local DIGITS = "23456789"                           -- no 0, 1
local SYMBOL = "!@#$%^&*()-_=+[]{};:,.?/"

-- Ambiguous glyphs re-added when the user does NOT ask to avoid them.
local AMBIG_LOWER  = "l"
local AMBIG_UPPER  = "IO"
local AMBIG_DIGITS = "01"

local function poolsFor(ctx)
    local avoid = ctx.opt("avoidAmbiguous")
    local pools = {}
    if ctx.opt("lowercase") then pools[#pools + 1] = LOWER  .. (avoid and "" or AMBIG_LOWER)  end
    if ctx.opt("uppercase") then pools[#pools + 1] = UPPER  .. (avoid and "" or AMBIG_UPPER)  end
    if ctx.opt("digits")    then pools[#pools + 1] = DIGITS .. (avoid and "" or AMBIG_DIGITS) end
    if ctx.opt("symbols")   then pools[#pools + 1] = SYMBOL end
    return pools
end

local function pick(ctx, s)
    local i = ctx.randomInt(1, #s)
    return s:sub(i, i)
end

-- Build a password of `length` from `pools`, one guaranteed char per pool, then
-- a Fisher-Yates shuffle so the guaranteed chars are not stuck at the front.
local function build(ctx, length, pools)
    local all = table.concat(pools)
    local chars = {}
    for _, p in ipairs(pools) do
        if #chars < length then chars[#chars + 1] = pick(ctx, p) end
    end
    while #chars < length do chars[#chars + 1] = pick(ctx, all) end
    for i = #chars, 2, -1 do
        local j = ctx.randomInt(1, i)
        chars[i], chars[j] = chars[j], chars[i]
    end
    return table.concat(chars)
end

local function generate(ctx)
    local pools = poolsFor(ctx)
    if #pools == 0 then
        ctx.notify("Password Generator", "Enable at least one character set in Settings")
        return
    end

    local length = ctx.opt("length")
    if length < #pools then
        -- Too short to honor every category; widen so each still appears.
        length = #pools
    end

    local pw = build(ctx, length, pools)
    ctx.pasteboardWrite(pw)
    ctx.notify("Password copied", length .. "-character password is on the clipboard")
    ctx.log("generated a", length, "char password (", #pools, "char classes)")
    return pw   -- returned for tests; ignored by the trigger path
end

return {
    api         = 1,
    id          = "password_generator",
    name        = "Password Generator",
    description = "Generate a strong random password and copy it to the clipboard.",
    version     = "1.0.0",
    category    = "productivity",
    context     = "anywhere",
    recommended = true,

    options = {
        { key = "length",         type = "int",  default = 20, label = "Length",            min = 8, max = 128 },
        { key = "lowercase",      type = "bool", default = true, label = "Include lowercase" },
        { key = "uppercase",      type = "bool", default = true, label = "Include uppercase" },
        { key = "digits",         type = "bool", default = true, label = "Include digits" },
        { key = "symbols",        type = "bool", default = true, label = "Include symbols" },
        { key = "avoidAmbiguous", type = "bool", default = true, label = "Avoid ambiguous (0 O 1 l I)" },
    },

    defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "p" },
    mnemonic = "P for Password",
    action = generate,
}
