-- features/window_deck/colors.lua
--
-- PURE LEAF: the deck's border-color palette and the positional dealing that
-- previews each window's color in the picker. No state -- the persisted per-app
-- colors are passed IN (the `stored` map), so the dealing algorithm is a pure,
-- unit-testable function of (windows, stored).

local M = {}

-- Distinct per-window border colors ("#RRGGBB"). Positional by default; the
-- picker previews each window's color as a dot the user can click to recolor
-- (cycling this palette), and the chosen color persists per APP (bundle id) so
-- decks look stable session to session.
M.PALETTE = {
    "#4C8DFF", "#34C759", "#FF9F0A", "#AF52DE", "#FF375F",
    "#5AC8FA", "#FFD60A", "#FF6482", "#30D158",
}

-- Preview colors for the pick list: an app the user has recolored keeps its
-- stored color (its first window), everyone else takes the next free palette
-- color positionally, skipping colors already in use.
---@param wins table[] window rows (each with .bundleID)
---@param stored table<string,string> per-app persisted colors (bundleID -> "#RRGGBB")
---@return string[] out cell i -> "#RRGGBB"
function M.assign(wins, stored)
    stored = stored or {}
    local used, out, seenApp = {}, {}, {}
    for i, w in ipairs(wins) do
        local bid = w.bundleID or ""
        if bid ~= "" and stored[bid] and not seenApp[bid] then
            out[i], used[stored[bid]], seenApp[bid] = stored[bid], true, true
        end
    end
    -- Positional dealing scans the WHOLE palette (cyclically from the last deal)
    -- for a FREE color; only when every color is taken does it knowingly reuse
    -- one, cyclically. DEFENSIVE, not a bug fix: with today's numbers (deck cap
    -- 9 == #PALETTE) exhaustion is provably unreachable and the simpler
    -- forward-only walk dealt identically -- this shape just stays correct if
    -- the palette shrinks or the cap ever lifts.
    local pi = 0
    for i in ipairs(wins) do
        if not out[i] then
            local c
            for step = 1, #M.PALETTE do
                local cand = M.PALETTE[((pi + step - 1) % #M.PALETTE) + 1]
                if not used[cand] then
                    c, pi = cand, pi + step
                    break
                end
            end
            if not c then
                pi = pi + 1
                c = M.PALETTE[((pi - 1) % #M.PALETTE) + 1]
            end
            out[i], used[c] = c, true
        end
    end
    return out
end

return M
