-- test/cases/_integration/platform/generated_secret_privacy.lua -- a secret a
-- feature GENERATES must not land in another feature's durable store.
--
-- This case lives at the altitude of the DEFECT, which is the wiring between two
-- features rather than anything inside either. Password Generator was correct on
-- its own (it produced a strong password and copied it) and Clipboard History was
-- correct on its own (it skipped every clip a password manager marked). Between
-- them the generated password was an ORDINARY clip, so history wrote it to disk
-- in plaintext, and neither feature's own case file could see it: each was only
-- ever asked about itself.
--
-- The guard at the bottom is the general form -- any feature that mints a
-- credential goes through ctx.pasteboardWriteConcealed -- because the next
-- generator to be added would otherwise re-introduce exactly this bug while both
-- of the specific assertions above it stayed green.

return {
    id = "generated_secret_privacy",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry
        local histPath = "/fake/data/clipboard_history/history.json"

        registry.register(require("features.password_generator"))
        registry.register(require("features.clipboard_history"))
        fake.settings["hammerdeck.opt.password_generator.length"] = 24
        registry.setEnabled("password_generator", true)
        registry.setEnabled("clipboard_history", true)

        -- An ordinary copy first: proves history is RUNNING and recording. Without
        -- this the assertions below would pass just as well against a history that
        -- never started, which is the same green for the opposite reason.
        fake.copyText("an ordinary note")
        fake.fireTimers("every", 0.8)
        ok(fake.files[histPath] and fake.files[histPath]:find("an ordinary note", 1, true) ~= nil,
            "control: Clipboard History is live and recording ordinary clips")

        -- Now generate. The trigger path, not the function directly -- the bug was
        -- in what the ACTION did, so calling generate() would prove nothing.
        local ran = registry.runAction("password_generator", nil)
        ok(ran == true, "the generator action ran")
        local pw = fake.pasteboard
        ok(type(pw) == "string" and #pw == 24,
            "the generator put a 24-char password on the clipboard")
        ok(fake.pasteboardConcealed == true,
            "the generated password is written CONCEALED, not as an ordinary clip")

        fake.fireTimers("every", 0.8)
        local hist = fake.files[histPath] or ""
        ok(hist:find(pw, 1, true) == nil,
            "a generated password is NEVER persisted to clipboard history")
        ok(hist:find("an ordinary note", 1, true) ~= nil,
            "...while the ordinary clip that preceded it is still there")

        registry.setEnabled("password_generator", false)
        registry.setEnabled("clipboard_history", false)

        -- The class guard. A feature that MINTS a credential must mark it; a plain
        -- ctx.pasteboardWrite leaves it an ordinary clip for any history to keep.
        -- Scanned per feature over the whole lua/ folder, the same enumeration the
        -- other cross-feature guards use -- a generator written into a sibling
        -- module would otherwise report nothing.
        do
            local appdir = require("loader").appdir
            local fh = io.popen("ls '" .. appdir .. "/features' 2>/dev/null")
            local ids = {}
            if fh then
                for line in fh:lines() do if line ~= "" then ids[#ids + 1] = line end end
                fh:close()
            end
            ok(#ids > 0, "secret guard: the catalog enumerated")

            -- Scope: a feature that MINTS a credential. Judged on the id, which
            -- is the only signal available to a text scan -- so this catches a
            -- second `password_*` or `*_token` feature and misses one called
            -- `api_key_maker`. That limit is real and is why part 1 above, the
            -- cross-feature reproduction, is the load-bearing half of this case;
            -- this is a cheap second net, not the guarantee.
            --
            -- No exemption list: every id that matches these words is a generator
            -- by definition. text_actions / clipboard_history / quick_sites write
            -- the clipboard too, but they move the user's OWN text around and
            -- none of them matches, so listing them would be three dead rows
            -- reading as reviewed decisions.
            local SECRET_WORDS = { "password", "secret", "token", "passphrase", "credential" }

            local offenders, scanned, inScope = {}, 0, 0
            for _, id in ipairs(ids) do
                local fh2 = io.popen("find '" .. appdir .. "/features/" .. id
                    .. "/lua' -name '*.lua' 2>/dev/null")
                local paths = {}
                if fh2 then
                    for line in fh2:lines() do if line ~= "" then paths[#paths + 1] = line end end
                    fh2:close()
                end
                local mints, marks = false, false
                for _, path in ipairs(paths) do
                    local f = io.open(path, "r")
                    if f then
                        local src2 = f:read("a"); f:close()
                        scanned = scanned + 1
                        for line in src2:gmatch("[^\n]+") do
                            local code = line:match("^%s*%-%-") and "" or line
                            if code:find("pasteboardWrite%s*%(") then mints = true end
                            if code:find("pasteboardWriteConcealed%s*%(") then marks = true end
                        end
                    end
                end
                local looksSecret = false
                for _, word in ipairs(SECRET_WORDS) do
                    if id:find(word, 1, true) then looksSecret = true; break end
                end
                if looksSecret then
                    inScope = inScope + 1
                    if mints and not marks then offenders[#offenders + 1] = id end
                end
            end
            -- Both landmarks matter: the scan found files at all, and the SCOPE is
            -- non-empty. A zero-member scope would make the verdict below green
            -- for the one reason that proves nothing -- it never looked at
            -- anything. (password_generator is the member that keeps it honest.)
            ok(scanned >= #ids, "secret guard: every feature contributed at least one file")
            ok(inScope > 0,
                "secret guard: the credential-minting scope is non-empty (" .. inScope .. ")")
            ok(#offenders == 0,
                "every credential-minting feature writes its secret CONCEALED (unmarked: "
                .. (#offenders > 0 and table.concat(offenders, ", ") or "none") .. ")")
        end
    end,
}
