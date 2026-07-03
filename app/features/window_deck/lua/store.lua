-- features/window_deck/store.lua
--
-- Deck PERSISTENCE: the three things a deck remembers between sessions -- each
-- app's chosen border color, the draggable widget's position, and hero-mode --
-- all in feature state (ctx.getState/setState) as JSON. `new(ctx)` returns a
-- small typed surface so init.lua's controller reads/writes them by name instead
-- of scattering six getState/setState + json wrappers through the state machine.
--
-- Not a pure leaf (it closes over ctx's state store), but it touches ONLY
-- ctx.getState/setState -- never native or the seam -- and requires only the
-- json leaf util. All shape/round-trip concerns (empty map -> {} not []) live
-- here, in one place.

local json = require("platform.json")

local M = {}

---@param ctx table the scoped feature ctx (getState/setState)
function M.new(ctx)
    local s = {}

    -- Per-app border colors (bundleID -> "#RRGGBB"). Object-tagged on encode so
    -- an empty map round-trips as {} not [].
    ---@return table<string,string>
    function s.readColors()
        local raw = ctx.getState("colors")
        if type(raw) ~= "string" or raw == "" then return {} end
        return json.decode(raw) or {}
    end
    ---@param map table<string,string>
    function s.saveColors(map)
        ctx.setState("colors", json.encode(json.asObject(map)))
    end

    -- The draggable widget's position, persisted as an OFFSET (dx, dy) from the
    -- deck screen's top-left so it survives a screen move/reconfig. Default: a
    -- small top-left inset.
    ---@return number dx, number dy
    function s.readWidgetPos()
        local raw = ctx.getState("widgetPos")
        if type(raw) == "string" and raw ~= "" then
            local p = json.decode(raw)
            if type(p) == "table" and type(p.dx) == "number" and type(p.dy) == "number" then
                return p.dx, p.dy
            end
        end
        return 20, 20
    end
    ---@param dx number
    ---@param dy number
    function s.saveWidgetPos(dx, dy)
        ctx.setState("widgetPos", json.encode(json.asObject({ dx = dx, dy = dy })))
    end

    -- Hero mode: whether focusing a deck window ZOOMS it into a centered hero
    -- (on, default) or leaves the deck a flat grid tiler (off). Persisted so the
    -- last choice is remembered; set from both the picker and the widget toggle.
    ---@return boolean
    function s.readHeroMode()
        return ctx.getState("heroMode") ~= "off"   -- default on
    end
    ---@param on boolean
    function s.saveHeroMode(on)
        ctx.setState("heroMode", on and "on" or "off")
    end

    return s
end

return M
