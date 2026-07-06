-- test/cases/text_actions.lua -- text_actions: capture the current selection (via a
-- synthesized cmd+c), then open/transform/paste it back. Covers URL passthrough, the
-- four base transforms, the math sandbox, dict:// + a custom dict app, the AI actions
-- (gated on a VALIDATED key), per-action toggles, translate's {lang} template, and the
-- empty-selection path.
--
-- Migrated from run.lua T22 (RUN_LUA_SPLIT_SPEC Phase 2). Hermetic: registers its own
-- feature and seeds its own selection/HTTP/settings per assertion; freshWorld() before +
-- handle tripwire after keep it isolated.

return {
    id = "text_actions",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry
        local OPENAI_TEST_URL = "https://api.openai.com/v1/chat/completions"

        -- urls.encodeComponent: unreserved passthrough, space, and per-octet UTF-8
        do
            local u = require("platform.urls")
            ok(u.encodeComponent("aZ9-_.~") == "aZ9-_.~", "encodeComponent: unreserved set passes through")
            ok(u.encodeComponent("a b") == "a%20b", "encodeComponent: space -> %20")
            ok(u.encodeComponent("词") == "%E8%AF%8D", "encodeComponent: CJK char -> UTF-8 octets")
        end

        registry.register(require("features.text_actions"))
        registry.setEnabled("text_actions", true)

        local function invokeOnSelection(text)
            fake.pasteboard = nil
            fake.pressHotkey("o")
            local last = fake.keyEvents[#fake.keyEvents]
            ok(last.key == "c" and last.mods[1] == "cmd", "invocation synthesizes cmd+c")
            fake.pasteboard = text            -- the "copied selection" arrives
            fake.fireTimers("after", 0.15)    -- the settle timer reads it
        end

        -- a URL selection opens directly, no picker
        invokeOnSelection("  https://example.test/page  ")
        ok(fake.openedUrls[#fake.openedUrls] == "https://example.test/page",
            "URL selection opens (trimmed), no picker")
        ok(fake.openDialog() == nil, "no picker for URLs")

        -- lowercase pastes back over the selection. Not validated -> only the four base
        -- transforms appear (the six AI entries are gated on a VALIDATED key, the flag
        -- the host sets on a successful Validate -- NOT mere key presence).
        invokeOnSelection("Hello WORLD")
        local dlg = fake.openDialog()
        ok(dlg ~= nil and #dlg.actions == 4, "not validated: picker offers only the four base actions")
        dlg.choose("lowercase")
        ok(fake.pasteboard == "hello world", "lowercase result lands on the clipboard")
        ok(fake.keyEvents[#fake.keyEvents].key == "v", "and is pasted back (cmd+v)")

        -- calculate evaluates the selection in a math-only sandbox
        invokeOnSelection("6*7")
        fake.openDialog().choose("Calculate")
        ok(fake.pasteboard == "42", "calculate replaces the selection with just the result")
        invokeOnSelection("os.exit()")
        fake.openDialog().choose("Calculate")
        ok(fake.pasteboard == "os.exit()", "sandbox: non-math globals are nil (eval fails, alert)")
        ok(fake.alerts[#fake.alerts]:match("Calculation failed") ~= nil, "failed eval alerts")

        -- dictionary (default, empty dictApp): opens the macOS Dictionary via dict://,
        -- the word percent-encoded. A CJK word must encode per UTF-8 octet.
        invokeOnSelection("ubiquitous")
        fake.openDialog().choose("Dictionary")
        ok(fake.openedUrls[#fake.openedUrls] == "dict://ubiquitous",
            "default Dictionary opens dict:// with the word")
        invokeOnSelection("词典")
        fake.openDialog().choose("Dictionary")
        ok(fake.openedUrls[#fake.openedUrls] == "dict://%E8%AF%8D%E5%85%B8",
            "CJK word percent-encoded per UTF-8 byte for dict://")

        -- dictionary (custom app override): launch/focus by bundle id, paste, return.
        fake.settings["hammerdeck.opt.text_actions.dictApp"] = "com.youdao.dict"
        fake.uninstalledApps = { ["com.youdao.dict"] = true }
        invokeOnSelection("ubiquitous")
        fake.openDialog().choose("Dictionary")
        ok(fake.alerts[#fake.alerts]:match("Could not open the dictionary app") ~= nil,
            "an unresolvable dict app alerts")
        fake.uninstalledApps = nil
        invokeOnSelection("ubiquitous")
        fake.openDialog().choose("Dictionary")
        fake.fireTimers("after", 0.75)
        ok(fake.launchedApps[#fake.launchedApps] == "com.youdao.dict",
            "custom dict app launched/focused by bundle id")
        ok(fake.pasteboard == "ubiquitous"
            and fake.keyEvents[#fake.keyEvents].key == "return",
            "the word is pasted into the custom dict + return")

        -- the Settings "Test" button (option-action) looks up a fixed word, no selection
        fake.settings["hammerdeck.opt.text_actions.dictApp"] = "com.youdao.dict"
        ok(registry.runOptionAction("text_actions", "dictApp") == true, "dictApp test option-action runs")
        fake.fireTimers("after", 0.75)
        ok(fake.launchedApps[#fake.launchedApps] == "com.youdao.dict", "test launches the dict app")
        ok(fake.pasteboard == "peace", "test pastes the fixed word 'peace'")
        ok(registry.runOptionAction("text_actions", "nope") == false, "an unknown option-action is refused")
        fake.settings["hammerdeck.opt.text_actions.dictApp"] = nil

        -- a key present but NOT yet validated still shows no AI entries (gating is on
        -- the validated flag, not key presence).
        fake.secrets["hammerdeck.opt.text_actions.openaiKey"] = "sk-test"
        invokeOnSelection("draft text")
        ok(#fake.openDialog().actions == 4, "key present but unvalidated: still only the four base actions")
        fake.openDialog().choose(nil)

        -- AI actions: appear once the key validates (host sets the validated state flag),
        -- send the selection to OpenAI, and paste the reply back.
        fake.settings["hammerdeck.state.text_actions.openaiKey__validated"] = true
        fake.httpResponses[OPENAI_TEST_URL] =
            { status = 200, body = '{"choices":[{"message":{"content":"  REFINED  "}}]}' }
        invokeOnSelection("draft text")
        local aiDlg = fake.openDialog()
        ok(#aiDlg.actions == 10, "validated: picker offers the four base + six AI actions")
        aiDlg.choose("AI: Refine")
        local req = fake.httpRequests[#fake.httpRequests]
        ok(req.url == OPENAI_TEST_URL and req.method == "POST", "AI action POSTs to OpenAI")
        ok(req.headers["Authorization"] == "Bearer sk-test"
            and req.headers["Content-Type"] == "application/json", "carries auth + json headers")
        local sent = require("platform.json").decode(req.body)
        ok(sent.model == "gpt-4o-mini" and sent.messages[2].content == "draft text",
            "request body carries the model and the selected text as the user message")
        ok(fake.pasteboard == "REFINED", "AI result trimmed and pasted back")
        ok(sent.messages[1].content:match("^Refine and improve") ~= nil,
            "default refine system prompt sent when not customized")

        -- the per-action system prompt is editable: a custom aiRefinePrompt is what gets sent
        fake.settings["hammerdeck.opt.text_actions.aiRefinePrompt"] = "Make it pirate-speak."
        invokeOnSelection("draft text")
        fake.openDialog().choose("AI: Refine")
        local custom = require("platform.json").decode(fake.httpRequests[#fake.httpRequests].body)
        ok(custom.messages[1].content == "Make it pirate-speak.",
            "customized refine prompt is sent as the system message")
        fake.settings["hammerdeck.opt.text_actions.aiRefinePrompt"] = nil

        -- per-action toggles: disabling an action removes it from the popup (key set)
        fake.settings["hammerdeck.opt.text_actions.showCalculate"] = false
        fake.settings["hammerdeck.opt.text_actions.showAiSummary"] = false
        invokeOnSelection("draft text")
        local toggled = fake.openDialog()
        ok(#toggled.actions == 8, "disabling one base + one AI action drops both from the picker")
        local seen = {}
        for _, a in ipairs(toggled.actions) do seen[a] = true end
        ok(not seen["Calculate"] and not seen["AI: Summary"], "the disabled actions are absent")
        ok(seen["Dictionary"] and seen["AI: Refine"], "the still-enabled actions remain")
        toggled.choose(nil)   -- dismiss without acting (onChoose(nil))
        fake.settings["hammerdeck.opt.text_actions.showCalculate"] = nil
        fake.settings["hammerdeck.opt.text_actions.showAiSummary"] = nil

        -- translate prompts for a language, then weaves it into the system prompt
        invokeOnSelection("hello")
        fake.openDialog().choose("AI: Translate")
        fake.openTextPrompt().submit("French")
        ok(fake.httpRequests[#fake.httpRequests].method == "POST", "translate fires after the language prompt")
        local tReq = require("platform.json").decode(fake.httpRequests[#fake.httpRequests].body)
        ok(tReq.messages[1].content:match("French") ~= nil, "target language woven into the system prompt")

        -- a custom translate template's {lang} token is substituted with the entered language
        fake.settings["hammerdeck.opt.text_actions.aiTranslatePrompt"] = "Render into {lang} only."
        invokeOnSelection("hello")
        fake.openDialog().choose("AI: Translate")
        fake.openTextPrompt().submit("Japanese")
        local tReq2 = require("platform.json").decode(fake.httpRequests[#fake.httpRequests].body)
        ok(tReq2.messages[1].content == "Render into Japanese only.",
            "custom translate template substitutes {lang}")
        fake.settings["hammerdeck.opt.text_actions.aiTranslatePrompt"] = nil

        -- failure path: a non-200 alerts and does not paste
        fake.pasteboard = "untouched"
        fake.httpResponses[OPENAI_TEST_URL] = { status = 500, body = "oops" }
        invokeOnSelection("draft text")
        fake.openDialog().choose("AI: Refine")
        ok(fake.alerts[#fake.alerts]:match("AI request failed") ~= nil, "AI failure alerts")
        fake.secrets["hammerdeck.opt.text_actions.openaiKey"] = nil
        fake.settings["hammerdeck.state.text_actions.openaiKey__validated"] = nil

        -- empty selection: trusted -> plain alert (no AX prompt)
        fake.pressHotkey("o")
        fake.pasteboard = nil
        fake.fireTimers("after", 0.15)
        ok(fake.alerts[#fake.alerts]:match("Nothing selected") ~= nil, "empty selection says so")

        registry.setEnabled("text_actions", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after text_actions test")
    end,
}
