-- Git Repo Picker: a searchable panel of the Git repositories under the
-- configured folders; choosing one opens it in the configured editor app.
--
-- Every open scans the folders with /usr/bin/find. That takes a fraction of a
-- second at the default depth, and longer with each extra level or on a
-- network or slow drive. No list is cached: the panel shows a Scanning row
-- until the result replaces it. Only the recently-opened map is persisted, to
-- put the repositories you use first.
--
-- A worked example: test/cases/_integration/platform/example_extensions.lua
-- loads it through the real extension loader and drives it end to end, so the
-- ctx shapes it relies on are checked by the test suite, not only described.

local repos = require("extensions.repo_picker.repos")
local json = require("platform.json")

local FIND = "/usr/bin/find"
local OPEN = "/usr/bin/open"
local DEFAULT_ROOTS = "~/Developer\n~/Projects\n~/code"
local DEFAULT_DEPTH, MIN_DEPTH, MAX_DEPTH = 3, 1, 6
local DEFAULT_EDITOR = "Visual Studio Code"
local RECENT_LIMIT = 200

-- Feature state holds only bool/number/string, so lists are stored as JSON.
-- json.decode / json.encode return nil + an error rather than raising.
local function loadJSON(ctx, key)
    local raw = ctx.getState(key)
    if type(raw) ~= "string" or raw == "" then return nil end
    local value, err = json.decode(raw)
    if type(value) == "table" then return value end
    ctx.log("state '" .. key .. "' unreadable; ignored: " .. tostring(err or type(value)))
    return nil
end

-- setState(key, nil) would DELETE the stored value, so a failed encode must
-- skip the write rather than pass its nil through.
local function saveJSON(ctx, key, value)
    local text, err = json.encode(value)
    if not text then
        ctx.log("state '" .. key .. "' not saved: " .. tostring(err))
        return
    end
    ctx.setState(key, text)
end

local function session(ctx)
    return ctx.perEnable(function()
        return { chooser = nil, current = nil }
    end)
end

local function config(ctx)
    local home = ctx.homeDir()
    local text = ctx.opt("roots")
    if type(text) ~= "string" then text = DEFAULT_ROOTS end
    local roots, invalid = repos.expandRoots(text, home)
    local depth = math.floor(tonumber(ctx.opt("maxDepth")) or DEFAULT_DEPTH)
    depth = math.max(MIN_DEPTH, math.min(MAX_DEPTH, depth))
    local shown = {}
    for i, r in ipairs(roots) do shown[i] = repos.tildify(r, home) end
    return { home = home, roots = roots, invalid = invalid, depth = depth,
             rootsText = table.concat(shown, ", ") }
end

local function reasonFor(ctx, program, code, errOut)
    if code == nil then
        return ctx.t("reasonNoLaunch", "could not start %s", program)
    elseif code < 0 then
        return ctx.t("reasonStopped", "timed out or was stopped before finishing")
    end
    return repos.firstLine(errOut)
        or ctx.t("reasonExit", "exited with code %s", tostring(code))
end

local function messageRow(text, subText)
    return { text = text, subText = subText or "", valid = false }
end

local function repoRows(ctx, paths, home)
    local recent = loadJSON(ctx, "recent") or {}
    local rows = {}
    for _, path in ipairs(repos.sorted(paths, recent)) do
        local name, parent = repos.split(path)
        rows[#rows + 1] = { text = name, subText = repos.tildify(parent, home), path = path }
    end
    return rows
end

local function recordRecent(ctx, path)
    local recent = loadJSON(ctx, "recent") or {}
    recent[path] = ctx.now()
    saveJSON(ctx, "recent", repos.capRecent(recent, RECENT_LIMIT))
end

local function openRepo(ctx, row)
    local app = repos.trim(tostring(ctx.opt("editorApp") or ""))
    if app == "" then app = DEFAULT_EDITOR end
    local function tellUser(reason)
        ctx.notify(
            ctx.t("openFailedTitle", "Couldn't open repository"),
            ctx.t("openFailedBody", "Opening %1$s in %2$s failed: %3$s", row.text, app, reason))
    end
    local ok, err = pcall(ctx.run, OPEN, { "-a", app, row.path }, function(code, _, errOut)
        ctx.log(string.format("open exit=%s app=%s path=%s", tostring(code), app, row.path))
        if code == 0 then
            recordRecent(ctx, row.path)
        else
            tellUser(reasonFor(ctx, OPEN, code, errOut))
        end
    end)
    if not ok then
        ctx.log("open launch error: " .. tostring(err))
        tellUser(reasonFor(ctx, OPEN, nil, nil))
    end
end

-- The chooser has already hidden itself by the time onSelect runs. `row` is nil
-- when the panel was dismissed; an info row (valid = false) never arrives here.
local function onSelect(ctx, row)
    if type(row) ~= "table" then
        ctx.log("dismissed; nothing chosen")
        return
    end
    ctx.log("chosen " .. row.path)
    openRepo(ctx, row)
end

local function chooserFor(ctx, s)
    if not s.chooser then
        s.chooser = ctx.chooser({
            searchSubText = true,
            onSelect = function(row) onSelect(ctx, row) end,
        })
        ctx.log("chooser created")
    end
    return s.chooser
end

local function setRows(ctx, s, rows, why)
    s.chooser.setChoices(rows)
    ctx.log(string.format("%s: %d rows, panel %s", why, #rows,
        s.chooser.isVisible() and "open" or "closed"))
end

local function failureText(ctx, cfg, failure)
    return ctx.t("failureDetail", "%1$s: %2$s",
        repos.tildify(failure.root, cfg.home), failure.reason)
end

local function tildifyAll(list, home)
    local out = {}
    for i, p in ipairs(list) do out[i] = repos.tildify(p, home) end
    return table.concat(out, ", ")
end

local function addFailure(ctx, result, root, reason)
    result.failures[#result.failures + 1] = { root = root, reason = reason }
    ctx.log("root failed: " .. root .. ": " .. reason)
end

local function finishScan(ctx, s, cfg, result)
    local paths = repos.unique(result.found)
    local failures, missing = result.failures, result.missing
    ctx.log(string.format("scan done repos=%d missing=%d failures=%d exits=%s elapsed=%ds",
        #paths, #missing, #failures, table.concat(result.exits, ","), ctx.now() - result.started))
    local rows
    if #paths == 0 and #failures == 0 and #missing == #cfg.roots then
        rows = { messageRow(
            ctx.t("allMissing", "None of the folders to scan exist"),
            ctx.t("allMissingDetail", "Not found: %s", tildifyAll(missing, cfg.home))) }
    elseif #paths == 0 and #failures > 0 and #failures + #missing >= #cfg.roots + #cfg.invalid then
        rows = { messageRow(
            ctx.t("failed", "Couldn't scan for Git repositories"),
            failureText(ctx, cfg, failures[1])) }
    else
        if #paths == 0 then
            local notSearched, searched = {}, {}
            for _, root in ipairs(missing) do notSearched[root] = true end
            for _, f in ipairs(failures) do notSearched[f.root] = true end
            for _, root in ipairs(cfg.roots) do
                if not notSearched[root] then searched[#searched + 1] = root end
            end
            rows = { messageRow(
                ctx.t("none", "No Git repositories found"),
                ctx.t("noneDetail", "Searched %1$s, %2$s levels deep",
                    tildifyAll(searched, cfg.home), tostring(cfg.depth))) }
        else
            rows = repoRows(ctx, paths, cfg.home)
        end
        if #failures > 0 then
            rows[#rows + 1] = messageRow(
                ctx.t("partial", "Some folders couldn't be fully scanned"),
                failureText(ctx, cfg, failures[1]))
        end
    end
    setRows(ctx, s, rows, "scan applied")
end

-- What one root's find run means. A missing root is skipped without a row
-- (the defaults name several layouts); a folder BELOW the root that find could
-- not read, or that vanished mid-scan, is expected and only logged.
local function rootOutcome(ctx, result, root, code, errOut)
    if code == nil or code < 0 then
        addFailure(ctx, result, root, reasonFor(ctx, FIND, code, nil))
        return
    end
    if code == 0 then return end
    local e = repos.classifyFindErrors(root, errOut)
    if #e.skippedBelow > 0 then
        ctx.log(string.format("%s: %d folder(s) below it skipped, first %s",
            root, #e.skippedBelow, e.skippedBelow[1]))
    end
    if e.missing then
        result.missing[#result.missing + 1] = root
        ctx.log("root skipped, not found: " .. root)
    elseif e.blocked then
        -- find runs without Hammerdeck's privacy grants, so no grant can fix this.
        addFailure(ctx, result, root, ctx.t("reasonProtected",
            "macOS doesn't let helper programs read this folder (Desktop, Documents, Downloads "
            .. "and iCloud Drive are protected); keep repositories somewhere else"))
    elseif #e.other > 0 or #e.skippedBelow == 0 then
        addFailure(ctx, result, root, reasonFor(ctx, FIND, code, table.concat(e.other, "\n")))
    end
end

-- Every open starts its own scan, and stop() on the previous scan's finds that
-- are still running is what keeps its result off the screen: a stopped one-shot
-- never delivers, so that scan never finishes. No flag is held across scans, so
-- nothing can be left stuck.
local function scan(ctx, s, cfg)
    local previous = s.current
    if previous and next(previous.handles) then
        local n = 0
        for _, h in pairs(previous.handles) do
            h.stop()
            n = n + 1
        end
        ctx.log(string.format("previous scan stopped: %d root(s) still running, a newer open started",
            n))
    end
    local result = { handles = {}, found = {}, failures = {}, missing = {}, exits = {},
                     started = ctx.now() }
    s.current = result
    for _, line in ipairs(cfg.invalid) do
        addFailure(ctx, result, line, ctx.t("reasonRelative", "not an absolute path"))
    end
    if #cfg.roots == 0 then
        ctx.log("scan not started: no roots (" .. #cfg.invalid .. " invalid)")
        local rows
        if #result.failures > 0 then
            rows = { messageRow(ctx.t("failed", "Couldn't scan for Git repositories"),
                failureText(ctx, cfg, result.failures[1])) }
        else
            rows = { messageRow(ctx.t("noRoots", "No folders to scan"),
                ctx.t("noRootsDetail", "Add folders in Settings under Git Repo Picker")) }
        end
        setRows(ctx, s, rows, "no roots")
        return
    end

    ctx.log(string.format("scan start roots=%s depth=%d", table.concat(cfg.roots, ","), cfg.depth))
    local pending = #cfg.roots
    local function done(i, root, code, out, errOut)
        result.handles[i] = nil
        result.exits[i] = code == nil and "nolaunch" or tostring(code)
        for _, p in ipairs(repos.parseFindOutput(out or "")) do
            result.found[#result.found + 1] = p
        end
        rootOutcome(ctx, result, root, code, errOut)
        pending = pending - 1
        if pending == 0 then finishScan(ctx, s, cfg, result) end
    end
    for i, root in ipairs(cfg.roots) do
        -- ctx.run raises when the exec trampoline is missing. Caught, the root
        -- counts as failed and the scan still completes; uncaught, the panel
        -- would sit on its Scanning row.
        local ok, handle = pcall(ctx.run, FIND, repos.findArgs(root, cfg.depth), function(code, out, errOut)
            done(i, root, code, out, errOut)
        end)
        if not ok then
            ctx.log("find launch error for " .. root .. ": " .. tostring(handle))
            done(i, root, nil, nil, nil)
        elseif result.exits[i] == nil then
            result.handles[i] = handle   -- still running; a synchronous delivery already set exits[i]
        end
    end
end

-- The panel opens on an unselectable Scanning row, which the scan result
-- replaces once. The highlight cannot be on a repository before that, so there
-- is no refill to race an arrow key.
local function openPicker(ctx)
    local s = session(ctx)
    local cfg = config(ctx)
    local h = chooserFor(ctx, s)
    h.setPlaceholder(ctx.t("placeholder", "Search Git repositories…"))
    h.setQuery(nil)   -- the panel keeps the last query; start every open empty
    setRows(ctx, s, { messageRow(ctx.t("scanning", "Scanning for Git repositories…"), cfg.rootsText) },
        "opened")
    h.show()
    scan(ctx, s, cfg)
end

return {
    api = 1,
    id = "repo_picker",
    actions = {
        {
            id = "open",
            label = "Open Git repo in editor",
            defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "g" },
            run = openPicker,
        },
    },
    options = {
        { key = "roots", type = "string", multiline = true, default = DEFAULT_ROOTS,
          label = "Folders to scan",
          hint = "One folder per line; ~ means your home folder. Folders that don't exist are "
              .. "skipped. Avoid network or slow drives: the panel waits for the slowest folder. "
              .. "macOS doesn't let helper programs read Desktop, Documents, Downloads "
              .. "or iCloud Drive, so keep repositories elsewhere. Worktrees and submodules "
              .. "(a .git file, not a folder) are not listed." },
        { key = "maxDepth", type = "int", default = DEFAULT_DEPTH, min = MIN_DEPTH, max = MAX_DEPTH,
          label = "Search depth",
          hint = "How many folder levels below each folder a repository can be; "
              .. "1 finds only the repositories directly inside it. Each extra level "
              .. "makes every open slower." },
        { key = "editorApp", type = "string", default = DEFAULT_EDITOR,
          label = "Editor app",
          hint = "The app a chosen repository opens in, by name." },
    },
}
