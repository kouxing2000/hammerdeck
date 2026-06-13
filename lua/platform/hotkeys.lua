-- platform/hotkeys.lua
--
-- Tiny shared hotkey helpers (used by the window / tab switchers).

local hotkeys = {}

-- The modifier a "release-to-pick" switcher should watch, derived from the
-- hotkey trigger that opened it -- so rebinding the trigger retargets the
-- release automatically, with no separate option to keep in sync. Prefers
-- alt, then cmd / ctrl / shift among the trigger's modifiers. Returns nil
-- when `spec` is not a hotkey (e.g. the action was fired from the menubar);
-- the caller then picks with Enter instead of on key-release.
local MOD_PRIORITY = { "alt", "cmd", "ctrl", "shift" }

function hotkeys.cycleModifier(spec)
    if not (spec and spec.type == "hotkey") then return nil end
    local has = {}
    for _, m in ipairs(spec.mods or {}) do has[m] = true end
    for _, m in ipairs(MOD_PRIORITY) do
        if has[m] then return m end
    end
    return nil
end

return hotkeys
