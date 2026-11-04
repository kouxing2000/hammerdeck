-- test/cases/text_actions.lua -- text_actions: capture the current selection (via a
-- synthesized cmd+c), then open/transform/paste it back. Covers URL passthrough, the
-- four base transforms, the math sandbox, dict:// + a custom dict app, the AI actions
-- (gated on a VALIDATED key; editing ones paste back, reading ones open the follow-up
-- chat window), per-action toggles, translate's {lang} template, and the
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

        -- A chat window's conversation as one comparable line: "role: text | ...".
        local function said(c)
            local out = {}
            for _, turn in ipairs(c.turns) do out[#out + 1] = turn.role .. ": " .. turn.text end
            return table.concat(out, " | ")
        end

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
        local baseIcon = {}
        for i, lbl in ipairs(dlg.actions) do baseIcon[lbl] = dlg.items[i].image end
        ok(baseIcon["lowercase"] == "symbol:characters.lowercase" and baseIcon["Calculate"] == "symbol:function",
            "base transforms carry a leading glyph in the picker")
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
        local aiIcon = {}
        for i, lbl in ipairs(aiDlg.actions) do aiIcon[lbl] = aiDlg.items[i].image end
        ok(aiIcon["AI: Refine"] == "symbol:wand.and.stars" and aiIcon["AI: Translate"] == "symbol:globe",
            "AI entries carry their own glyphs")
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
        ok(fake.alerts[#fake.alerts] == "AI: Refine: pasted, and on your clipboard",
            "an editing action says where the reply went (a read-only paste lands nowhere)")
        local refineBanner = fake.banners[#fake.banners]
        ok(refineBanner.text == "AI: Refine …" and refineBanner.stopped,
            "a banner shows while the request runs and goes when the reply lands")

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
        local tChat = fake.openChat()
        ok(tChat ~= nil and said(tChat) == "user: Translate into French\nhello | assistant: REFINED"
            and not tChat.busy,
            "translate's reply opens in the chat window, under the request it answers")
        ok(fake.pasteboard == "hello", "and is not pasted over the selection")
        tChat.close()

        -- a custom translate template's {lang} token is substituted with the entered language
        fake.settings["hammerdeck.opt.text_actions.aiTranslatePrompt"] = "Render into {lang} only."
        invokeOnSelection("hello")
        fake.openDialog().choose("AI: Translate")
        fake.openTextPrompt().submit("Japanese")
        local tReq2 = require("platform.json").decode(fake.httpRequests[#fake.httpRequests].body)
        ok(tReq2.messages[1].content == "Render into Japanese only.",
            "custom translate template substitutes {lang}")
        fake.openChat().close()
        fake.settings["hammerdeck.opt.text_actions.aiTranslatePrompt"] = nil

        -- summary, a reading action, opens its reply in the chat window, and the
        -- window carries the conversation on
        local json = require("platform.json")
        invokeOnSelection("long article text")
        fake.openDialog().choose("AI: Summary")
        local sReq = json.decode(fake.httpRequests[#fake.httpRequests].body)
        ok(not sReq.messages[1].content:lower():find("language", 1, true),
            "the default summary prompt names no language (a language clause got English text "
            .. "summarized in Spanish)")
        local chat = fake.openChat()
        ok(chat ~= nil and said(chat) == "user: long article text | assistant: REFINED",
            "the window opens on the selection as the first turn, the summary under it")
        ok(fake.pasteboard == "long article text", "and is not pasted over the selection")
        chat.send("why?")
        local fReq = json.decode(fake.httpRequests[#fake.httpRequests].body)
        ok(#fReq.messages == 4 and fReq.messages[3].role == "assistant"
            and fReq.messages[3].content == "REFINED" and fReq.messages[4].content == "why?",
            "a follow-up resends the whole conversation, reply included")
        ok(chat.open and said(chat)
            == "user: long article text | assistant: REFINED | user: why? | assistant: REFINED",
            "the window shows the question and the new reply")
        local sentSoFar = #fake.httpRequests
        chat.send("   ")
        ok(#fake.httpRequests == sentSoFar, "a blank Enter sends nothing")

        -- while a reply is on its way the window holds the next question back, so
        -- every reply lands under the question it answers
        fake.deferAsync = true
        chat.send("and then?")
        ok(chat.busy, "a typing bubble shows while the reply is on its way")
        chat.send("one more")
        ok(#fake.httpRequests == sentSoFar + 1 and chat.turns[#chat.turns].text == "and then?",
            "a question typed meanwhile is neither sent nor shown")
        fake.deliverAsync()
        ok(not chat.busy and chat.turns[#chat.turns].role == "assistant",
            "the reply lands under its question")
        chat.send("one more")
        ok(#fake.httpRequests == sentSoFar + 2, "then the next question goes out")
        local qReq = json.decode(fake.httpRequests[#fake.httpRequests].body)
        ok(qReq.messages[#qReq.messages].content == "one more"
            and qReq.messages[#qReq.messages - 1].role == "assistant",
            "after that reply, keeping the conversation in order")
        -- Escape while that one is still out: the window closes and the late reply is dropped
        local before = said(chat)
        chat.close()
        ok(not chat.open, "Escape closes the window")
        fake.deliverAsync()
        ok(said(chat) == before, "the reply still in flight is dropped")
        fake.deferAsync = false
        -- free ask: the instruction typed for it heads the request in the history
        invokeOnSelection("long article text")
        fake.openDialog().choose("AI: Free ask")
        fake.openTextPrompt().submit("make it formal")
        local askChat = fake.openChat()
        ok(said(askChat) == "user: make it formal\nlong article text | assistant: REFINED",
            "free ask shows the instruction over the selection, then the reply")
        askChat.close()
        local closedLogged = false
        for _, l in ipairs(fake.logs) do
            if l:find("ai aiSummary: chat closed after 3 replies", 1, true) then closedLogged = true end
        end
        ok(closedLogged, "closing the window logs how many replies it held")

        -- failure path: a non-200 alerts and does not paste
        fake.pasteboard = "untouched"
        fake.httpResponses[OPENAI_TEST_URL] = { status = 500, body = "oops" }
        invokeOnSelection("draft text")
        fake.openDialog().choose("AI: Refine")
        ok(fake.alerts[#fake.alerts]:match("AI request failed") ~= nil, "AI failure alerts")
        invokeOnSelection("draft text")
        fake.openDialog().choose("AI: Summary")
        local failedChat = fake.openChat()
        ok(said(failedChat) == "user: draft text | note: AI request failed (500)",
            "a failed reply shows in the window as a note")
        local function lastSent()
            local out = {}
            for _, m in ipairs(json.decode(fake.httpRequests[#fake.httpRequests].body).messages) do
                out[#out + 1] = m.content
            end
            return table.concat(out, " | ")
        end
        fake.httpResponses[OPENAI_TEST_URL] =
            { status = 200, body = '{"choices":[{"message":{"content":"OK"}}]}' }
        failedChat.send("still there?")
        ok(lastSent():find("draft text | still there?", 1, true) ~= nil,
            "after a failed first reply the selection stays in the conversation")
        fake.httpResponses[OPENAI_TEST_URL] = { status = 500, body = "oops" }
        failedChat.send("lost question")
        fake.httpResponses[OPENAI_TEST_URL] =
            { status = 200, body = '{"choices":[{"message":{"content":"OK"}}]}' }
        failedChat.send("next question")
        ok(not lastSent():find("lost question", 1, true) and lastSent():find("next question", 1, true),
            "a question whose request failed is not resent with the next one")
        ok(said(failedChat):find("user: lost question | note: AI request failed (500)", 1, true) ~= nil,
            "though it stays on screen with its failure")
        failedChat.close()
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
