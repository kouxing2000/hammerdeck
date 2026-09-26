-- Pure helpers for repo_picker: no ctx, no I/O, so they run under plain Lua.

local M = {}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
M.trim = trim

--- First non-empty line of a process stream, capped so a notification stays readable.
---@param s string|nil
---@return string|nil
function M.firstLine(s)
    if type(s) ~= "string" then return nil end
    for raw in s:gmatch("[^\n]+") do
        local line = trim(raw)
        if line ~= "" then
            if #line > 200 then line = line:sub(1, 197) .. "..." end
            return line
        end
    end
    return nil
end

--- The `roots` option (one path per line) -> absolute roots, `~` expanded.
--- Lines that are still relative after expansion are returned in `invalid`:
--- the child runs from `/`, so a relative root would silently scan the wrong place.
---@param text string
---@param home string
---@return string[] roots, string[] invalid
function M.expandRoots(text, home)
    local roots, invalid, seen = {}, {}, {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local p = trim(line)
        if p ~= "" then
            if p == "~" then
                p = home
            elseif p:sub(1, 2) == "~/" then
                p = home .. p:sub(2)
            end
            if #p > 1 then p = p:gsub("/+$", "") end
            if p:sub(1, 1) ~= "/" then
                invalid[#invalid + 1] = trim(line)
            elseif not seen[p] then
                seen[p] = true
                roots[#roots + 1] = p
            end
        end
    end
    return roots, invalid
end

--- argv for /usr/bin/find: prune node_modules, print each `.git` DIRECTORY
--- (and do not descend into it) of a repository at most `depth` folder levels
--- below `root`. `-maxdepth` counts the `.git` folder itself, hence depth + 1.
--- `-H` follows `root` when it is a symlink (find's default `-P` would list
--- nothing and exit 0); links found BELOW the root stay unfollowed, so there
--- is no loop to guard against.
---@param root string
---@param depth integer
---@return string[]
function M.findArgs(root, depth)
    return {
        "-H", root, "-maxdepth", tostring(depth + 1),
        "-name", "node_modules", "-prune",
        "-o", "-type", "d", "-name", ".git", "-prune", "-print",
    }
end

local NOT_FOUND = "No such file or directory"
local NOT_PERMITTED = "Operation not permitted"   -- macOS privacy protection
local DENIED = "Permission denied"                -- ordinary file permissions

--- The path of a `find: <path>: <reason>` line when it ends in `reason`.
--- Matched from the END, so a path that itself contains ": " stays whole.
local function errorPath(line, reason)
    local suffix = ": " .. reason
    if line:sub(1, 6) ~= "find: " or line:sub(-#suffix) ~= suffix then return nil end
    return line:sub(7, #line - #suffix)
end

---@class FindErrors
---@field missing boolean        the root itself does not exist
---@field blocked boolean        macOS refused to let find read the root itself
---@field skippedBelow string[]  folders below the root find could not read (macOS protection
---                              or permissions) or that vanished mid-scan -- expected: a
---                              protected folder under ~, a database volume inside a repo,
---                              a build deleting its output
---@field other string[]         every other error line, verbatim

--- Sort find's stderr for one root by what the picker should do about it.
---@param root string
---@param errOut string|nil
---@return FindErrors
function M.classifyFindErrors(root, errOut)
    local r = { missing = false, blocked = false, skippedBelow = {}, other = {} }
    local below = root == "/" and "/" or (root .. "/")
    for raw in (errOut or ""):gmatch("[^\n]+") do
        local line = trim(raw)
        local gone, protected = errorPath(line, NOT_FOUND), errorPath(line, NOT_PERMITTED)
        local skipped = protected or errorPath(line, DENIED) or gone
        if line == "" then
            -- nothing to classify
        elseif gone == root then
            r.missing = true
        elseif protected == root then
            r.blocked = true
        elseif skipped and skipped:sub(1, #below) == below then
            r.skippedBelow[#r.skippedBelow + 1] = skipped
        else
            r.other[#r.other + 1] = line
        end
    end
    return r
end

--- find's stdout -> repo paths (the parent of each `.git`).
---@param out string
---@return string[]
function M.parseFindOutput(out)
    local paths = {}
    for line in (out or ""):gmatch("[^\n]+") do
        local repo = line:match("^(/.-)/%.git$")
        if repo and repo ~= "" then paths[#paths + 1] = repo end
    end
    return paths
end

---@param list string[]
---@return string[]
function M.unique(list)
    local out, seen = {}, {}
    for _, p in ipairs(list) do
        if not seen[p] then
            seen[p] = true
            out[#out + 1] = p
        end
    end
    return out
end

--- A path shown with the home directory as `~`.
---@param path string
---@param home string
---@return string
function M.tildify(path, home)
    if home and home ~= "" and home ~= "/" then
        if path == home then return "~" end
        if path:sub(1, #home + 1) == home .. "/" then return "~" .. path:sub(#home + 1) end
    end
    return path
end

--- Folder name and parent path of a repo.
---@param path string
---@return string name, string parent
function M.split(path)
    local parent, name = path:match("^(.*)/([^/]+)$")
    if not name then return path, "/" end
    if parent == "" then parent = "/" end
    return name, parent
end

--- Most-recently-opened first (by `recent[path]` timestamp), then by folder
--- name (case-insensitive), then by full path so the order is total.
---@param paths string[]
---@param recent table<string, number>
---@return string[]
function M.sorted(paths, recent)
    local list = {}
    for i, p in ipairs(paths) do list[i] = p end
    local keyName = {}
    for _, p in ipairs(list) do keyName[p] = (select(1, M.split(p))):lower() end
    table.sort(list, function(a, b)
        local ra, rb = recent[a], recent[b]
        if ra and rb and ra ~= rb then return ra > rb end
        if (ra ~= nil) ~= (rb ~= nil) then return ra ~= nil end
        if keyName[a] ~= keyName[b] then return keyName[a] < keyName[b] end
        return a < b
    end)
    return list
end

--- Keep only the `limit` most recent entries so the persisted map stays small.
---@param recent table<string, number>
---@param limit integer
---@return table<string, number>
function M.capRecent(recent, limit)
    local entries = {}
    for p, ts in pairs(recent) do entries[#entries + 1] = { p = p, ts = ts } end
    if #entries <= limit then return recent end
    table.sort(entries, function(a, b)
        if a.ts ~= b.ts then return a.ts > b.ts end
        return a.p < b.p
    end)
    local out = {}
    for i = 1, limit do out[entries[i].p] = entries[i].ts end
    return out
end

return M
