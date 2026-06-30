-- platform/text.lua
--
-- Tiny shared text helpers for the read-back layer (the rules sentence + the
-- effects chain describe). ZERO require; reached by the SUBSYSTEM modules
-- (rules / effects), not by features.

local M = {}

-- Lowercase ONLY the first character, so a fragment reads mid-sentence
-- ("Minimize it" -> "minimize it"). ASCII-first; non-English is left as-is (the
-- whole read-back is English, like the rest of the describe layer).
---@param s string
---@return string
function M.lowerFirst(s)
    if type(s) ~= "string" or #s == 0 then return s end
    return s:sub(1, 1):lower() .. s:sub(2)
end

return M
