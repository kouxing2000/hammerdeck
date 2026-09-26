-- test/cases/_integration/platform/example_extensions.lua -- the worked examples
-- under examples/extensions/ are GATED, not just shipped.
--
-- An example is the complete, end-to-end illustration of the extension
-- contract, and the authoring guide describes the same ctx shapes (chooser,
-- getState/setState, perEnable, ctx.run) in prose no test reads. Loading and
-- driving the examples here makes those shapes tested claims: a ctx change that
-- breaks an example turns this red instead of leaving a published example that
-- no longer runs.
--
-- Per example, ENUMERATED FROM DISK (so a new one cannot skip the gate):
--   * it loads through the real extension loader with no load failure, and
--     enables with no start failure. The folder list comes from the disk, not
--     from the loader's discovery, so a folder the loader would silently pass
--     over (no lua/init.lua) fails here instead of vanishing;
--   * registry.validateExtension is fully clean -- the verdict the
--     validate_extension MCP tool gives an author -- AND it read every lua/
--     file. The walk reads through adapter.fileRead, so a file it cannot read
--     is simply absent from the verdict, which would look clean;
--   * i18n: every literal ctx.t / ctx.plural key is UNDOTTED and has an entry
--     in each shipped catalog, and no catalog key is orphaned (an action.* /
--     option.* key must name a real action id / option key). Undotted,
--     because tFeature falls back to the shared global catalog for a dotted
--     key the feature catalog lacks, so a dotted key could quietly show a
--     platform string in any locale the example does not translate.
-- Then repo_picker's behaviour is driven through the fake, against a small
-- model of find (root -> stdout/stderr/status): the find argv, how each root's
-- errors are classified (missing, protected, skipped below, other), the
-- Scanning row the panel opens on and the one result that replaces it, an
-- older scan never replacing a newer one, the open argv for a pick, MRU order,
-- and the notification a failed open posts.
--
-- Integration (platform core). Hermetic: freshWorld() precedes the case and
-- registry.reset() detaches the loader's extensions root.

local EXT_DIR = "examples/extensions"

---@param path string
---@return string|nil
local function readDisk(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- Lines a shell listing prints, sorted (the io.popen scan harness.discover uses).
---@param cmd string
---@return string[]
local function listDisk(cmd)
    local out = {}
    local pipe = io.popen(cmd)
    if not pipe then return out end
    for line in pipe:lines() do out[#out + 1] = line end
    pipe:close()
    table.sort(out)
    return out
end

return {
    id = "example_extensions",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry, manifest = t.ok, t.fake, t.registry, t.manifest
        local json = require("platform.json")
        local appdir = require("loader").appdir

        -- ---------------------------------------------------------------
        -- Enumerate and load every example.
        -- ---------------------------------------------------------------
        local ids = {}
        for _, dir in ipairs(listDisk('find "' .. EXT_DIR .. '" -mindepth 1 -maxdepth 1 -type d')) do
            ids[#ids + 1] = dir:match("([^/]+)$")
        end
        ok(#ids > 0, "examples/extensions/ lists at least one example (no vacuous pass)")
        local hasRepoPicker = false
        for _, id in ipairs(ids) do if id == "repo_picker" then hasRepoPicker = true end end
        ok(hasRepoPicker, "the repo_picker example is among them")

        fake.settings["hammerdeck.extensionsDir"] = EXT_DIR
        fake.featuresByDir[EXT_DIR] = ids
        local loaded = registry.loadExtensions()
        local loadErrs = {}
        for _, f in ipairs(registry.failures().load) do
            loadErrs[#loadErrs + 1] = tostring(f.source) .. ": " .. tostring(f.error)
        end
        ok(#loadErrs == 0, "every example loads -- failures: " .. table.concat(loadErrs, "; "))
        ok(loaded == #ids, "every example folder loaded as an extension ("
            .. loaded .. "/" .. #ids .. ")")

        for _, id in ipairs(ids) do
            local root = EXT_DIR .. "/" .. id

            -- Enable: no start failure.
            registry.setEnabled(id, true)
            ok(registry.failures().start[id] == nil,
                id .. ": enables without a start failure -- " .. tostring(registry.failures().start[id]))
            registry.setEnabled(id, false)

            -- validateExtension, fed the REAL sources through fake.files.
            local luaFiles = listDisk('find "' .. root .. '/lua" -type f -name "*.lua"')
            local expectScanned, seeded = {}, {}
            for _, path in ipairs(luaFiles) do
                local rel = path:sub(#root + #"/lua/" + 1):gsub("%.lua$", ""):gsub("/", ".")
                expectScanned[#expectScanned + 1] =
                    rel == "init" and ("extensions." .. id) or ("extensions." .. id .. "." .. rel)
                fake.files[path] = readDisk(path)
                seeded[#seeded + 1] = path
            end
            for name in pairs(manifest.FEATURE_REQUIRABLE) do
                local path = appdir .. "/platform/lua/" .. name .. ".lua"
                fake.files[path] = readDisk(path)
                seeded[#seeded + 1] = path
            end
            local r = registry.validateExtension(id)
            ok(r.error == nil, id .. ": validateExtension ran -- " .. tostring(r.error))
            ok(#r.underDeclared == 0,
                id .. ": no under-declared capability -- " .. table.concat(r.underDeclared, ","))
            ok(#r.overDeclared == 0,
                id .. ": no over-declared capability -- " .. table.concat(r.overDeclared, ","))
            ok(#r.withdrawn == 0, id .. ": no withdrawn call -- " .. table.concat(r.withdrawn, "; "))
            ok(#r.disallowedRequires == 0,
                id .. ": no disallowed require -- " .. table.concat(r.disallowedRequires, ","))
            ok(r.ok == true, id .. ": validateExtension verdict is ok")
            local scanned = {}
            for _, name in ipairs(r.scanned) do scanned[name] = true end
            for _, name in ipairs(expectScanned) do
                ok(scanned[name], id .. ": the validator read " .. name
                    .. " (scanned: " .. table.concat(r.scanned, ",") .. ")")
            end
            for _, path in ipairs(seeded) do fake.files[path] = nil end

            -- i18n: the keys the source asks for vs the catalogs it ships.
            local asked = {}
            for _, path in ipairs(luaFiles) do
                local src = readDisk(path) or ""
                for key in src:gmatch([=[ctx%.t%(%s*["']([^"']+)["']]=]) do asked[key] = true end
                for key in src:gmatch([=[ctx%.plural%(%s*["']([^"']+)["']]=]) do asked[key] = true end
            end
            if id == "repo_picker" then
                ok(asked["openFailedBody"] == true,
                    "the ctx.t key scan finds repo_picker's keys (no vacuous pass)")
            end
            for key in pairs(asked) do
                ok(not key:find(".", 1, true), id .. ": ctx.t key '" .. key
                    .. "' is undotted (a dotted key falls back to the shared catalog)")
            end
            -- Manifest strings are keyed by the action ids / option keys the
            -- registered manifest really has; anything else must be a ctx.t key.
            local actionIds, optionKeys = {}, {}
            for _, m in ipairs(registry.all()) do
                if m.id == id then
                    for _, a in ipairs(m.actions or {}) do actionIds[a.id] = true end
                    for _, o in ipairs(m.options or {}) do optionKeys[o.key] = true end
                end
            end
            for _, path in ipairs(listDisk('find "' .. root .. '/i18n" -type f -name "*.json" 2>/dev/null')) do
                local cat = json.decode(readDisk(path) or "")
                ok(type(cat) == "table", path .. " parses as a JSON object")
                ---@cast cat table<string, any>
                for key in pairs(asked) do
                    ok(cat[key] ~= nil, path .. " translates ctx.t key '" .. key .. "'")
                end
                for key in pairs(cat) do
                    local action, option = key:match("^action%.([^.]+)%."), key:match("^option%.([^.]+)%.")
                    local used = key == "name" or key == "description" or asked[key]
                        or (action and actionIds[action]) or (option and optionKeys[option])
                    ok(used, path .. ": key '" .. key .. "' is used (name/description, a real "
                        .. "action id or option key, or a ctx.t key in the source)")
                end
            end
        end

        -- ---------------------------------------------------------------
        -- repo_picker's pure stderr classifier, on canned find output in the
        -- real `find: <path>: <reason>` shape.
        -- ---------------------------------------------------------------
        do
        local repos = require("extensions.repo_picker.repos")
        local R = "/r/code"
        local e = repos.classifyFindErrors(R, "find: /r/code: No such file or directory\n")
        ok(e.missing and not e.blocked and #e.other == 0,
            "classifier: the root itself not existing is 'missing'")
        e = repos.classifyFindErrors(R, "find: /r/code: Operation not permitted\n")
        ok(e.blocked and not e.missing and #e.skippedBelow == 0 and #e.other == 0,
            "classifier: the root itself refused by macOS is 'blocked'")
        e = repos.classifyFindErrors(R, "find: /r/code/a: b: Operation not permitted\n")
        ok(not e.blocked and #e.other == 0 and #e.skippedBelow == 1 and e.skippedBelow[1] == "/r/code/a: b",
            "classifier: a folder BELOW the root macOS refuses is 'skippedBelow', its name kept whole")
        e = repos.classifyFindErrors(R, "find: /r/code/app/data/postgres: Permission denied\n")
        ok(not e.blocked and #e.other == 0 and #e.skippedBelow == 1
                and e.skippedBelow[1] == "/r/code/app/data/postgres",
            "classifier: a folder BELOW the root its permissions deny is 'skippedBelow'")
        e = repos.classifyFindErrors(R, "find: /r/code/web/.next/cache: No such file or directory\n")
        ok(not e.missing and #e.other == 0 and #e.skippedBelow == 1
                and e.skippedBelow[1] == "/r/code/web/.next/cache",
            "classifier: a folder BELOW the root that vanished mid-scan is 'skippedBelow', not 'missing'")
        e = repos.classifyFindErrors(R, "find: /r/code2/x: Operation not permitted\n")
        ok(#e.other == 1 and #e.skippedBelow == 0 and not e.blocked,
            "classifier: a sibling folder that merely shares the root's prefix is 'other'")
        e = repos.classifyFindErrors(R, "find: /r/code: Permission denied\n")
        ok(not e.blocked and #e.skippedBelow == 0 and #e.other == 1,
            "classifier: the root ITSELF denied by its permissions stays 'other' (a failure row)")
        e = repos.classifyFindErrors(R, nil)
        ok(not e.missing and not e.blocked and #e.skippedBelow == 0 and #e.other == 0,
            "classifier: no stderr, nothing to report")
        end

        -- ---------------------------------------------------------------
        -- repo_picker, driven end to end.
        -- ---------------------------------------------------------------
        local HOME = fake.adapter.homeDir()
        local FIND, OPEN = "/usr/bin/find", "/usr/bin/open"
        local ROOTS_KEY = "hammerdeck.opt.repo_picker.roots"
        local TWO = HOME .. "/Projects/alpha/.git\n" .. HOME .. "/Projects/work/beta/.git\n"

        local function rootOf(args)   -- find's start path: its first non-flag argument
            for _, a in ipairs(args) do if a:sub(1, 1) ~= "-" then return a end end
        end
        -- A small model of find: root -> what it reports. A root not listed
        -- does not exist, and find says so the way the real one does.
        local disk = {}
        fake.runResults[FIND] = function(args)
            local root = rootOf(args)
            return disk[root] or { status = 1, stderr = "find: " .. root .. ": No such file or directory\n" }
        end

        local function fire()
            local okRun, err = registry.runAction("repo_picker", "open")
            ok(okRun, "repo_picker.open ran -- " .. tostring(err))
            return fake.visibleChooser()
        end
        local function logsMention(...)   -- one log line containing every fragment
            local want = { ... }
            for _, line in ipairs(fake.logs) do
                local all = true
                for _, w in ipairs(want) do
                    if not line:find(w, 1, true) then all = false; break end
                end
                if all then return true end
            end
            return false
        end
        local function sameArgs(a, b)
            if #a ~= #b then return false end
            for i = 1, #a do if a[i] ~= b[i] then return false end end
            return true
        end
        local function findRootsSince(from)
            local roots = {}
            for i = from, #fake.runs do
                if fake.runs[i].path == FIND then roots[#roots + 1] = rootOf(fake.runs[i].args) end
            end
            return roots
        end

        registry.setEnabled("repo_picker", true)

        -- No default root exists: each is tried, none gets a failure row, and
        -- the one row says they are all missing.
        do
        local c = fire()
        ok(c ~= nil, "the picker panel is shown")
        local roots = findRootsSince(1)
        ok(sameArgs(roots, { HOME .. "/Developer", HOME .. "/Projects", HOME .. "/code" }),
            "find is run on each default root, in order -- got: " .. table.concat(roots, ","))
        ok(#c.choices == 1 and c.choices[1].text == "None of the folders to scan exist",
            "one row says none of the folders exist -- got: " .. tostring(c.choices[1] and c.choices[1].text))
        ok(c.choices[1].subText == "Not found: ~/Developer, ~/Projects, ~/code",
            "and lists them -- got: " .. tostring(c.choices[1].subText))
        ok(c.choices[1].valid == false, "that info row is not selectable (valid = false)")
        ok(logsMention("not found: " .. HOME .. "/Developer") and logsMention("not found: " .. HOME .. "/code"),
            "each missing root is logged as skipped")
        end

        -- Nothing configured at all is a different message.
        do
        fake.settings[ROOTS_KEY] = "  "
        local before = #fake.runs
        local c = fire()
        ok(#fake.runs == before, "with no folder configured, find is never run")
        ok(#c.choices == 1 and c.choices[1].text == "No folders to scan",
            "an empty list says there is nothing to scan")
        fake.settings[ROOTS_KEY] = nil
        end

        -- Picking the Scanning row (Return, or h.select on its row number)
        -- delivers nothing: onSelect never sees an info row, so the example
        -- carries no guard for one. The panel stays open for the real list.
        do
        fake.deferAsync = true
        local c = fire()
        local opens, selects = 0, 0
        for _, r in ipairs(fake.runs) do if r.path == OPEN then opens = opens + 1 end end
        local onSelect = c.opts.onSelect
        c.opts.onSelect = function(...) selects = selects + 1; return onSelect(...) end
        local okSel, err = pcall(c.userSelect, 1)
        c.opts.onSelect = onSelect
        ok(okSel, "picking the Scanning row does not raise -- " .. tostring(err))
        ok(selects == 0, "onSelect is not called for the Scanning row (" .. selects .. " calls)")
        ok(c.visible, "the panel stays open")
        local after = 0
        for _, r in ipairs(fake.runs) do if r.path == OPEN then after = after + 1 end end
        ok(after == opens, "and nothing is opened")
        fake.deliverAsync()
        fake.deferAsync = false
        end

        -- One default root exists. The panel opens on a Scanning row, and the
        -- result replaces it exactly once.
        disk[HOME .. "/Projects"] = { status = 0, stdout = TWO }
        local c
        do
        fake.deferAsync = true
        local from = #fake.runs + 1
        c = fire()
        ok(c.placeholder == "Search Git repositories…", "the search placeholder is set")
        ok(#c.choices == 1 and c.choices[1].text == "Scanning for Git repositories…"
                and c.choices[1].valid == false,
            "before the scan lands, the panel shows one unselectable Scanning row")
        ok(c.choices[1].subText == "~/Developer, ~/Projects, ~/code",
            "naming the folders being scanned -- got: " .. tostring(c.choices[1].subText))
        local calls = c.setChoicesCalls
        fake.deliverAsync()
        fake.deferAsync = false
        ok(c.setChoicesCalls == calls + 1, "the scan result replaces the Scanning row exactly once")
        local projects
        for i = from, #fake.runs do
            if rootOf(fake.runs[i].args) == HOME .. "/Projects" then projects = fake.runs[i] end
        end
        ok(projects ~= nil, "find ran on ~/Projects")
        -- find does the work, so the argv is the claim: -H follows a symlinked
        -- root, the default depth 3 is maxdepth 4 (the .git folder counts),
        -- node_modules is pruned, each .git DIRECTORY is printed and not entered.
        ok(sameArgs(projects.args, {
                "-H", HOME .. "/Projects", "-maxdepth", "4",
                "-name", "node_modules", "-prune",
                "-o", "-type", "d", "-name", ".git", "-prune", "-print" }),
            "find argv follows a symlinked root, reaches depth 3, prunes node_modules -- got: "
                .. table.concat(projects.args, " "))
        ok(#c.choices == 2, "both repos are listed and the missing roots add no row ("
            .. #c.choices .. " rows)")
        ok(c.choices[1].text == "alpha" and c.choices[1].subText == "~/Projects",
            "row 1 is alpha under ~/Projects (home shown as ~)")
        ok(c.choices[2].text == "beta" and c.choices[2].subText == "~/Projects/work",
            "row 2 is beta under ~/Projects/work")
        ok(c.choices[1].valid ~= false and c.choices[2].valid ~= false, "repo rows are selectable")
        end

        -- Pick beta (the SECOND row) through a typed query, so the MRU check
        -- below has an order to change and the next open has a query to clear.
        do
        c.userType("bet")
        c.userSelect(1)
        local run = fake.runs[#fake.runs]
        ok(run.path == OPEN, "picking a repo runs /usr/bin/open")
        ok(sameArgs(run.args, { "-a", "Visual Studio Code", HOME .. "/Projects/work/beta" }),
            "open argv is -a <editor> <repo path> -- got: " .. table.concat(run.args, " "))
        ok(#fake.notifications == 0, "a successful open posts no notification")
        end

        -- Open again: the query typed last time is gone, so the Scanning row is
        -- visible; then the repo just opened is listed first.
        do
        fake.deferAsync = true
        c = fire()
        ok((c.query or "") == "", "the query from the last open is cleared -- got: " .. tostring(c.query))
        ok(#c.choices == 1 and c.choices[1].text == "Scanning for Git repositories…",
            "so the Scanning row shows")
        fake.deliverAsync()
        fake.deferAsync = false
        ok(#c.choices == 2 and c.choices[1].text == "beta" and c.choices[2].text == "alpha",
            "the most recently opened repo is listed first")
        end

        -- A failed open tells the user why, and does not count as a recent open.
        do
        fake.runResults[OPEN] = { status = 1,
            stderr = "Unable to find application named 'Visual Studio Code'\n" }
        c.userSelect(2)
        ok(fake.runs[#fake.runs].path == OPEN and fake.runs[#fake.runs].args[3] == HOME .. "/Projects/alpha",
            "open was attempted for alpha")
        local note = fake.notifications[#fake.notifications]
        ok(#fake.notifications == 1 and note.title == "Couldn't open repository",
            "a failed open posts one notification")
        ok(note and note.text ==
            "Opening alpha in Visual Studio Code failed: Unable to find application named 'Visual Studio Code'",
            "the notification names the repo, the editor and open's own reason -- got: "
                .. tostring(note and note.text))
        c = fire()
        ok(c.choices[1].text == "beta", "a failed open does not move the repo up the list")
        end

        -- A good root next to one that fails on every scan (macOS protects it):
        -- the repos plus one row saying why, set exactly once after the panel opens.
        do
        fake.settings[ROOTS_KEY] = "~/Projects\n~/Documents/GitHub"
        disk[HOME .. "/Documents/GitHub"] = { status = 1,
            stderr = "find: " .. HOME .. "/Documents/GitHub: Operation not permitted\n" }
        fake.deferAsync = true
        c = fire()
        local calls = c.setChoicesCalls
        fake.deliverAsync()
        fake.deferAsync = false
        ok(c.setChoicesCalls == calls + 1, "the mixed result is set exactly once after the panel opens")
        ok(#c.choices == 3 and c.choices[1].path and c.choices[2].path,
            "both repos are listed, plus one row (" .. #c.choices .. " rows)")
        local last = c.choices[3]
        ok(last.text == "Some folders couldn't be fully scanned" and last.valid == false,
            "the last row says a folder could not be scanned -- got: " .. tostring(last.text))
        ok(last.subText == "~/Documents/GitHub: macOS doesn't let helper programs read this folder "
            .. "(Desktop, Documents, Downloads and iCloud Drive are protected); keep repositories "
            .. "somewhere else",
            "a protected root is explained, not shown as a raw error -- got: " .. tostring(last.subText))
        end

        -- No repos found, with one root failing: "Searched" names only the
        -- roots that were actually searched.
        do
        disk[HOME .. "/Projects"] = { status = 0, stdout = "" }
        c = fire()
        ok(#c.choices == 2 and c.choices[1].text == "No Git repositories found",
            "an empty scan says no repos were found, plus the failure row (" .. #c.choices .. " rows)")
        ok(c.choices[1].subText == "Searched ~/Projects, 3 levels deep",
            "and names only the root that completed -- got: " .. tostring(c.choices[1].subText))
        end

        -- find fails for the only root and prints nothing: one row says why,
        -- and the log names the root and the reason.
        do
        fake.settings[ROOTS_KEY] = "~/Projects"
        disk[HOME .. "/Projects"] = { status = 1,
            stderr = "find: " .. HOME .. "/Projects: Input/output error\n" }
        c = fire()
        ok(#c.choices == 1 and c.choices[1].text == "Couldn't scan for Git repositories"
                and c.choices[1].valid == false,
            "a scan where every root failed shows one row saying so (" .. #c.choices .. " rows)")
        ok(c.choices[1].subText == "~/Projects: find: " .. HOME .. "/Projects: Input/output error",
            "and why, in find's own words -- got: " .. tostring(c.choices[1].subText))
        ok(logsMention("root failed: " .. HOME .. "/Projects", "Input/output error"),
            "the log names the failed root AND its reason, so it explains the row on its own")
        end

        -- Two opens in a row: the second open stops the first one's find, and
        -- only the second result is shown, even if the first one's lands last.
        do
        disk[HOME .. "/Projects"] = { status = 0, stdout = TWO }
        fake.deferAsync = true
        c = fire()
        local liveAfterFirst = registry.liveHandleCount()
        disk[HOME .. "/Projects"] = { status = 0, stdout = TWO .. HOME .. "/Projects/gamma/.git\n" }
        c = fire()
        ok(registry.liveHandleCount() == liveAfterFirst,
            "opening again stops the first open's find (live handles "
                .. liveAfterFirst .. " -> " .. registry.liveHandleCount() .. ")")
        ok(logsMention("[repo_picker]", "stopped: 1 root(s) still running"),
            "the stopped scan is logged with how many roots were still running")
        local queued = fake.pendingAsync
        ok(#queued == 2, "both completions are queued (" .. #queued .. ")")
        local calls = c.setChoicesCalls
        fake.pendingAsync = {}
        queued[2]()   -- the newer scan lands first
        queued[1]()   -- then the stopped one
        fake.deferAsync = false
        ok(c.setChoicesCalls == calls + 1 and #c.choices == 3,
            "only the newer scan's result is shown (" .. #c.choices .. " rows)")
        end

        -- A folder BELOW a broad root that find could not read, or that
        -- vanished mid-scan, is expected: logged, no row.
        do
        fake.settings[ROOTS_KEY] = "~"
        fake.settings["hammerdeck.opt.repo_picker.maxDepth"] = 10   -- above the maximum
        disk[HOME] = { status = 1, stdout = HOME .. "/Projects/alpha/.git\n",
            stderr = "find: " .. HOME .. "/Library/Mail: Operation not permitted\n"
                .. "find: " .. HOME .. "/Projects/web/.next/cache: No such file or directory\n" }
        c = fire()
        ok(#c.choices == 1 and c.choices[1].path == HOME .. "/Projects/alpha",
            "a skipped folder below the root adds no row (" .. #c.choices .. " rows)")
        ok(logsMention(HOME .. "/Library/Mail"), "it is logged instead")
        local args = fake.runs[#fake.runs].args
        ok(rootOf(args) == HOME and args[3] == "-maxdepth" and args[4] == "7",
            "a stored depth above 6 is clamped to 6 (maxdepth 7) -- got: " .. table.concat(args, " "))
        fake.settings[ROOTS_KEY] = nil
        fake.settings["hammerdeck.opt.repo_picker.maxDepth"] = nil
        end

        registry.setEnabled("repo_picker", false)
    end,
}
