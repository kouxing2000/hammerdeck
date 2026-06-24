-- platform/json.lua
--
-- Minimal JSON decoder + encoder -- pure Lua, 5.4-compatible, no
-- dependencies. Decoder limitation: a JSON `null` becomes Lua nil, so null
-- object members vanish and a null inside an array truncates the ipairs view
-- at that point. Fine for the APIs we consume; don't feed it documents where
-- null position matters. Encoder: see the section below for its table rules.

local json = {}

-- Array-vs-object type tags (the dkjson `__jsontype` convention). A Lua table
-- can't express, on its own, whether it is a JSON array or object -- decisively
-- so when EMPTY (`{}` could be `[]` or `{}`). A metatable `__jsontype` field of
-- "array" | "object" pins the shape. It is honored by BOTH this encoder AND the
-- Swift bridge reader (`LuaState.any`), so a value's shape survives a round-trip
-- and a cross-language hop. Mark explicitly with `json.asObject`/`json.asArray`;
-- `json.decode` auto-tags what it parses, so decode->encode is shape-stable.
local OBJECT_MT = { __jsontype = "object" }
local ARRAY_MT  = { __jsontype = "array" }

---Tag `t` as a JSON object (encodes as `{}` even when empty). Returns `t`.
---@param t table
---@return table
function json.asObject(t) return setmetatable(t, OBJECT_MT) end

---Tag `t` as a JSON array (encodes as `[]`; only the 1..#t part). Returns `t`.
---@param t table
---@return table
function json.asArray(t) return setmetatable(t, ARRAY_MT) end

---The `__jsontype` tag on `t` ("array"|"object"), or nil if untagged.
---@param t table
---@return string|nil
local function jsonType(t)
    local mt = getmetatable(t)
    return mt and mt.__jsontype or nil
end

local function fail(msg, i)
    error("json: " .. msg .. " at byte " .. i, 0)
end

local function skip(s, i)
    return (s:find("[^ \t\r\n]", i)) or (#s + 1)
end

local ESCAPES = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
    b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

local function parseString(s, i)            -- i points at the opening quote
    local out, j = {}, i + 1
    while true do
        local c = s:sub(j, j)
        if c == "" then fail("unterminated string", i) end
        if c == '"' then return table.concat(out), j + 1 end
        if c == "\\" then
            local e = s:sub(j + 1, j + 1)
            if ESCAPES[e] then
                out[#out + 1] = ESCAPES[e]
                j = j + 2
            elseif e == "u" then
                local cp = tonumber(s:sub(j + 2, j + 5), 16)
                if not cp then fail("bad \\u escape", j) end
                j = j + 6
                -- surrogate pair -> astral code point
                if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j, j + 1) == "\\u" then
                    local lo = tonumber(s:sub(j + 2, j + 5), 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                        j = j + 6
                    end
                end
                out[#out + 1] = utf8.char(cp)
            else
                fail("bad escape '\\" .. e .. "'", j)
            end
        else
            out[#out + 1] = c
            j = j + 1
        end
    end
end

local function parseNumber(s, i)
    local str = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
    local n = str and tonumber(str)
    if not n then fail("bad value", i) end
    return n, i + #str
end

local parseValue
parseValue = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "" then fail("unexpected end of input", i) end

    if c == "{" then
        local obj = setmetatable({}, OBJECT_MT)   -- tagged so {} round-trips as {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            i = skip(s, i)
            if s:sub(i, i) ~= '"' then fail("expected object key", i) end
            local k; k, i = parseString(s, i)
            i = skip(s, i)
            if s:sub(i, i) ~= ":" then fail("expected ':'", i) end
            local v; v, i = parseValue(s, i + 1)
            obj[k] = v
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "," then i = i + 1
            elseif d == "}" then return obj, i + 1
            else fail("expected ',' or '}'", i) end
        end

    elseif c == "[" then
        local arr = setmetatable({}, ARRAY_MT)     -- tagged so [] round-trips as []
        i = skip(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            local v; v, i = parseValue(s, i)
            arr[#arr + 1] = v
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "," then i = i + 1
            elseif d == "]" then return arr, i + 1
            else fail("expected ',' or ']'", i) end
        end

    elseif c == '"' then
        return parseString(s, i)
    elseif s:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif s:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif s:sub(i, i + 3) == "null" then
        return nil, i + 4
    else
        return parseNumber(s, i)
    end
end

-- Decode a JSON document. Returns the value, or nil + error message. (A bare
-- `null` document is indistinguishable from failure -- acceptable here.)
function json.decode(s)
    if type(s) ~= "string" then return nil, "json: input is not a string" end
    local ok, v, rest = pcall(parseValue, s, 1)
    if not ok then return nil, v end
    if s:find("[^ \t\r\n]", rest) then return nil, "json: trailing garbage" end
    return v
end

-- ---------------------------------------------------------------------------
-- Minimal encoder (the counterpart: persist Lua state as JSON). Supports
-- nil/bool/number/string and tables. A table's shape: a `__jsontype` tag wins
-- (see json.asObject/asArray); otherwise #t > 0 => ARRAY, an untagged empty
-- table => `[]` (the historical default), else an OBJECT with STRING keys. A
-- table that mixes array entries with string keys is REJECTED (it would
-- silently lose the string keys) -- tag it to say which shape you meant. No
-- cycles. Numbers must be finite.
-- ---------------------------------------------------------------------------

local ENC_ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\",
    ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n",
    ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encString(s)
    return '"' .. s:gsub('[%z\1-\31"\\]', function(c)
        return ENC_ESCAPES[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function encValue(v, depth)
    if depth > 64 then error("json: nesting too deep (cycle?)", 0) end
    local t = type(v)
    if v == nil then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            error("json: non-finite number", 0)
        end
        if math.type and math.type(v) == "integer" then return tostring(v) end
        return string.format("%.14g", v)
    elseif t == "string" then return encString(v)
    elseif t == "table" then
        local tag = jsonType(v)
        local n = #v
        -- ARRAY: tagged "array", or (untagged) a non-empty sequence. Reject a
        -- mixed table loudly -- the string keys would otherwise just vanish.
        if tag == "array" or (tag == nil and n > 0) then
            for k in pairs(v) do
                if type(k) == "string" then
                    error("json: table mixes array entries with string key '"
                        .. k .. "'; tag it with json.asObject/asArray", 0)
                end
            end
            local out = {}
            for i = 1, n do out[i] = encValue(v[i], depth + 1) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        -- OBJECT: tagged "object", or an untagged empty table that we default to
        -- an array for back-compat (only a "object" tag forces empty -> `{}`).
        local out = {}
        for k, val in pairs(v) do
            if type(k) ~= "string" then
                error("json: object keys must be strings", 0)
            end
            out[#out + 1] = encString(k) .. ":" .. encValue(val, depth + 1)
        end
        if #out == 0 and tag ~= "object" then return "[]" end   -- historical default
        table.sort(out)                                         -- deterministic output
        return "{" .. table.concat(out, ",") .. "}"
    end
    error("json: cannot encode a " .. t, 0)
end

-- Encode a Lua value. Returns the JSON string, or nil + error message.
function json.encode(v)
    local ok, s = pcall(encValue, v, 0)
    if not ok then return nil, s end
    return s
end

return json
