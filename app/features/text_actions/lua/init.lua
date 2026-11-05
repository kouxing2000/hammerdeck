-- features/text_actions
--
-- Act on the currently SELECTED text in any app (ported from the author's
-- prior Hammerspoon config): synthesize cmd+C to capture the selection,
-- then either open it (URLs) or offer a picker of transforms that paste the
-- result back over the selection (cmd+V).
--
-- Actions: open URL, lowercase, UPPERCASE, calculate (evaluates the selection
-- as a Lua expression in a math-only sandbox), Dictionary (the macOS Dictionary
-- via dict:// by default; a custom app via launchOrFocus+paste+return if configured),
-- and -- once an OpenAI key is entered AND validated in Settings -- six AI
-- actions that send the selection to OpenAI chat completions. The EDITING ones
-- (refine, enrich, complete) paste the reply back over the selection; the
-- READING ones (summary, translate, freeAsk) open the reply in a follow-up chat
-- window instead, because the text they run on is often read-only (a web page,
-- a PDF), where a paste lands nowhere. The AI entries stay hidden until the key
-- validates (ctx.getState("openaiKey__validated")).
--
-- Every AI action's SYSTEM PROMPT is a per-action option (aiRefinePrompt, ...),
-- so the user can tune what each one asks the model -- the strings below are
-- just the defaults. Free ask has no fixed prompt (the user types it each run);
-- Translate's prompt carries a {lang} token replaced by the language entered.
--
-- Donor semantics kept: the clipboard is NOT saved/restored -- transforms
-- intentionally leave the result on the clipboard, and pastes are async.
-- Requires the Accessibility permission (keystroke synthesis); without it
-- macOS silently drops the synthesized cmd+C and the selection stays empty.

local json = require("platform.json")
local urls = require("platform.urls")

local COPY_SETTLE_SECONDS = 0.15   -- let the copied selection reach the clipboard
local OPENAI_URL = "https://api.openai.com/v1/chat/completions"

-- Base (non-AI) picker entries, each gated by its `opt` toggle so a user can
-- hide the ones they never use (all default on). `id` is the STABLE dispatch
-- key (locale-independent); `label` is the English default shown when no
-- translation exists. The picker is built with localized labels (ctx.t) and a
-- label->entry map, so onChoose dispatches by `id` -- display and comparison are
-- decoupled, and the labels can localize without breaking dispatch.
-- `icon` is an icon token (SF Symbol) shown as the entry's leading glyph in the
-- "act on selection" picker -- the same treatment the command palette gives an
-- action, applied to this in-app sub-menu so the transforms are scannable.
local BASE_ACTIONS = {
    { id = "dictionary", label = "Dictionary", opt = "showDictionary", icon = "symbol:character.book.closed" },
    { id = "lowercase",  label = "lowercase",  opt = "showLowercase",  icon = "symbol:characters.lowercase" },
    { id = "uppercase",  label = "UPPERCASE",  opt = "showUppercase",  icon = "symbol:characters.uppercase" },
    { id = "calculate",  label = "Calculate",  opt = "showCalculate",  icon = "symbol:function" },
}

-- Default system prompts for the AI actions. These seed the per-action prompt
-- OPTIONS below (aiRefinePrompt, ...) so the user can edit them in Settings; the
-- feature always reads the live value via ctx.opt(promptOpt), never these
-- constants directly. Translate's carries a {lang} token replaced at run time.
local PROMPTS = {
    refine = "Refine and improve the following text, fixing grammar and "
        .. "clarity while preserving its meaning and language. Return only the result.",
    enrich = "Expand and enrich the following text with more vivid detail, "
        .. "keeping its meaning and language. Return only the result.",
    complete = "Continue and complete the following text naturally. "
        .. "Return only the continuation appended to the original.",
    -- No language clause: with one ("in its own language", "in the same language
    -- as the text") gpt-4o-mini answers English text in Spanish; without one it
    -- answers in the text's language.
    summary = "Summarize the following text concisely. Return only the summary.",
    translate = "Translate the following into {lang}. Return only the translation.",
}

-- AI picker entries: each maps a label to its `opt` toggle and (except free ask)
-- a `promptOpt` -- the option key holding its editable system prompt. translate
-- and freeAsk are handled specially (they prompt for input first): translate
-- still has an editable prompt (with a {lang} token); free ask's prompt IS the
-- user's run-time instruction, so it has no promptOpt. `chat` marks a reading
-- action whose reply opens in the follow-up window; translate and freeAsk open
-- it too, once their input is in. AI entries appear only when BOTH the key is
-- validated and the entry's toggle is on.
local AI_ACTIONS = {
    { id = "aiRefine",    label = "AI: Refine",    opt = "showAiRefine",    promptOpt = "aiRefinePrompt",    icon = "symbol:wand.and.stars" },
    { id = "aiEnrich",    label = "AI: Enrich",    opt = "showAiEnrich",    promptOpt = "aiEnrichPrompt",    icon = "symbol:sparkles" },
    { id = "aiComplete",  label = "AI: Complete",  opt = "showAiComplete",  promptOpt = "aiCompletePrompt",  icon = "symbol:text.append" },
    { id = "aiSummary",   label = "AI: Summary",   opt = "showAiSummary",   promptOpt = "aiSummaryPrompt",   chat = true, icon = "symbol:list.bullet.rectangle" },
    { id = "aiTranslate", label = "AI: Translate", opt = "showAiTranslate", promptOpt = "aiTranslatePrompt", translate = true, icon = "symbol:globe" },
    { id = "aiFreeAsk",   label = "AI: Free ask",  opt = "showAiFreeAsk",   freeAsk = true,                  icon = "symbol:questionmark.bubble" },
}

-- Look `word` up in the dictionary: the user's custom app (launch/focus it --
-- the original HS launchOrFocus, so it opens even if quit -- then clear the
-- field, PASTE the word, and search; paste is more reliable than typing, esp.
-- for CJK) or, when none is configured, the macOS Dictionary via dict://. Shared
-- by the Dictionary action and the Settings "Test" button.
---@param ctx Ctx
local function lookupInDict(ctx, word)
    local app = ctx.opt("dictApp")   -- a bundle id, or "" for macOS Dictionary
    if app and app ~= "" then
        if not ctx.launchOrFocusApp(app) then
            ctx.alert(ctx.t("alert.noDictApp", "Could not open the dictionary app -- re-pick it in Settings"))
            return
        end
        ctx.afterSeconds(ctx.opt("dictDelayMs") / 1000, function()
            ctx.keyStroke({ "cmd" }, "a")
            ctx.pasteboardWrite(word)
            ctx.keyStroke({ "cmd" }, "v")
            ctx.keyStroke({}, "return")
        end)
    else
        ctx.openURL("dict://" .. urls.encodeComponent(word))
    end
end

-- Paste `text` back over the current selection (write the clipboard, then cmd+V).
---@param ctx Ctx
local function pasteBack(ctx, text)
    ctx.pasteboardWrite(text)
    ctx.keyStroke({ "cmd" }, "v")
end

---@class ChatMessage
---@field role "system"|"user"|"assistant"
---@field content string

-- The `code` OpenAI's error body names the failure by, or nil when the body has
-- none (a network failure, a proxy's HTML page).
---@param respBody string|nil
---@return string|nil
local function errorCode(respBody)
    local doc = json.decode(respBody)
    local err = type(doc) == "table" and doc.error or nil
    local code = type(err) == "table" and err.code or nil
    return type(code) == "string" and code or nil
end

-- Why a call failed, in words the user can act on: the three causes they can do
-- something about get their own message, anything else shows the HTTP status.
---@param ctx Ctx
---@param status integer|nil
---@param code string|nil
---@return string
local function failureReason(ctx, status, code)
    if code == "insufficient_quota" then
        return ctx.t("alert.aiNoCredit", "Your OpenAI account is out of credit")
    elseif code == "invalid_api_key" then
        return ctx.t("alert.aiBadKey", "OpenAI rejected the API key -- check it in Settings")
    elseif code == "context_length_exceeded" then
        return ctx.t("alert.aiTooLong", "The text is too long for the model")
    end
    return ctx.t("alert.aiFailed", "AI request failed (%s)", tostring(status))
end

-- The selection (already trimmed, see the action's run) as the chat window's
-- first bubble shows it: at most SHOWN_LINES lines and SHOWN_CHARS characters,
-- cut after a word when one ends in the second half, and "…" when anything was
-- left out. Display only: the model always gets the whole selection.
local SHOWN_CHARS, SHOWN_LINES = 300, 6
---@param text string
---@return string
local function excerpt(text)
    local cut, byChars = #text, false
    local lines, from = 0, 1
    while true do
        local nl = text:find("\n", from, true)
        if not nl then break end
        lines = lines + 1
        if lines == SHOWN_LINES then cut = nl - 1; break end
        from = nl + 1
    end
    -- utf8.offset keeps the cut on a character boundary (CJK is 3 bytes a char).
    local after = utf8.offset(text, SHOWN_CHARS + 1)
    if after and after <= cut then cut, byChars = after - 1, true end
    if cut >= #text then return text end
    local shown = text:sub(1, cut)
    -- A cut that already ends a word (whitespace follows) keeps that word.
    if byChars and not text:sub(cut + 1, cut + 1):match("%s") then
        local space = shown:match(".*()%s")
        if space and space > cut / 2 then shown = shown:sub(1, space - 1) end
    end
    return (shown:gsub("%s+$", "")) .. "…"
end

-- One chat-completions call over `messages`. Async (httpPost): `cb(reply)` gets
-- the trimmed reply, or `cb(nil, failure)` a localized reason. Logs what was sent
-- (sizes, never the text) and how it came back. Returns the request handle
-- (stop() drops a reply still in flight), or nil when no key is set.
---@param ctx Ctx
---@param what string the action id, for the log
---@param messages ChatMessage[]
---@param cb fun(reply: string|nil, failure: string|nil)
---@return { stop: fun() }|nil
local function requestAI(ctx, what, messages, cb)
    local key = ctx.secret("openaiKey")
    if not key or key == "" then
        ctx.log("ai " .. what .. ": no API key")
        cb(nil, ctx.t("alert.noKey", "Set an OpenAI API key in Settings first"))
        return nil
    end
    local model = ctx.opt("model")
    local wire, bytes = {}, 0
    for i, m in ipairs(messages) do
        wire[i] = json.asObject({ role = m.role, content = m.content })
        bytes = bytes + #m.content
    end
    local body = json.encode(json.asObject({ model = model, messages = json.asArray(wire) }))
    ctx.log(string.format("ai %s: sent (model %s, %d messages, %d bytes)",
        what, tostring(model), #messages, bytes))
    local started = ctx.now()
    return ctx.httpPost(OPENAI_URL, {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. key,
    }, body, function(status, respBody)
        local secs = ctx.now() - started
        if status ~= 200 or not respBody then
            local code = errorCode(respBody)
            ctx.log(string.format("ai %s: failed (status %s%s, %ds)", what, tostring(status),
                code and (", " .. code) or "", secs))
            cb(nil, failureReason(ctx, status, code))
            return
        end
        local doc = json.decode(respBody)
        local msg = doc and doc.choices and doc.choices[1] and doc.choices[1].message
        local result = msg and msg.content
        if type(result) ~= "string" then
            ctx.log(string.format("ai %s: status 200 but no reply text (%ds)", what, secs))
            cb(nil, ctx.t("alert.aiNoResult", "AI returned no result"))
            return
        end
        local reply = (result:gsub("^%s*(.-)%s*$", "%1"))
        ctx.log(string.format("ai %s: reply (%d bytes, %ds)", what, #reply, secs))
        cb(reply)
    end)
end

-- An EDITING action: send the selection, paste the reply back over it. A banner
-- shows while the request runs, and a toast says where the reply went -- over
-- read-only text the paste does nothing, and the clipboard still holds it.
---@param ctx Ctx
local function pasteAI(ctx, entry, content, systemPrompt)
    local label = ctx.t("action." .. entry.id, entry.label)
    local banner = ctx.banner(label .. " …")
    requestAI(ctx, entry.id, {
        { role = "system", content = systemPrompt },
        { role = "user",   content = content },
    }, function(reply, failure)
        banner.stop()
        if not reply then
            ctx.alert(failure)
            return
        end
        pasteBack(ctx, reply)
        ctx.log("ai " .. entry.id .. ": pasted back")
        ctx.alert(ctx.t("alert.pasted", "%s: pasted, and on your clipboard", label))
    end)
end

-- A READING action: the reply opens in a chat window (ctx.chat), where the
-- conversation shows as bubbles. It opens on the request -- what the user typed
-- for it (translate's target, free ask's instruction) over the selection's
-- opening lines (excerpt) -- and the whole selection is the first user message
-- the model gets; each follow-up adds a question and
-- sends the whole conversation again. The window holds a question back while a
-- reply is on its way, so turns stay in order. A question whose request failed
-- leaves the conversation the model sees (it stays on screen with the failure),
-- so the next one does not carry it along unanswered. Closing the window drops a
-- reply still in flight.
---@param ctx Ctx
---@param request string|nil
local function openChat(ctx, entry, content, systemPrompt, request)
    local label = ctx.t("action." .. entry.id, entry.label)
    ---@type ChatMessage[]
    local messages = {
        { role = "system", content = systemPrompt },
        { role = "user",   content = content },
    }
    -- What the window shows: the request, then replies, failures and questions.
    ---@type ChatTurnSpec[]
    local turns = { { role = "user", text = (request and (request .. "\n") or "") .. excerpt(content) } }
    local replies = 0
    local pending, chat = nil, nil
    local function show()
        if chat then chat.setMessages(turns, pending ~= nil) end
    end
    local function send()
        -- The reply can arrive before requestAI returns (no key), so `pending`
        -- is set only while the request is genuinely still out.
        local landed = false
        local handle = requestAI(ctx, entry.id, messages, function(reply, failure)
            landed = true
            pending = nil
            if reply then
                messages[#messages + 1] = { role = "assistant", content = reply }
                turns[#turns + 1] = { role = "assistant", text = reply }
                replies = replies + 1
            else
                if #messages > 2 then messages[#messages] = nil end
                turns[#turns + 1] = { role = "note", text = failure or "" }
            end
            show()
        end)
        if not landed then pending = handle end
    end
    chat = ctx.chat {
        title = label,
        placeholder = ctx.t("chat.placeholder", "Ask a follow-up"),
        onSend = function(text)
            if pending then
                ctx.log("ai " .. entry.id .. ": follow-up ignored, a reply is still on its way")
                return
            end
            messages[#messages + 1] = { role = "user", content = text }
            turns[#turns + 1] = { role = "user", text = text }
            send()
            show()
        end,
        onClose = function()
            if pending then pending.stop() end
            pending = nil
            ctx.log(string.format("ai %s: chat closed after %d replies", entry.id, replies))
            chat = nil
        end,
    }
    send()
    show()
end

-- Build the picker from the enabled toggles: base transforms, plus AI entries
-- only once the key is VALIDATED in Settings AND the entry's toggle is on (an
-- unvalidated key shows no AI noise). Labels are LOCALIZED; each row carries the
-- entry's stable `id`, which is what onChoose dispatches on. Returns
-- (actions, byId).
--
-- The byId map used to be keyed by the localized LABEL, because askChoice handed
-- the display text back. Two entries whose translations collided in some locale
-- would then have silently shared one slot -- last writer wins, wrong action
-- runs, no error. Keying by id (CODE-12) removes that entirely.
---@param ctx Ctx
local function buildPicker(ctx)
    local actions, byId = {}, {}
    local function addEntry(e)
        actions[#actions + 1] = { id = e.id, label = ctx.t("action." .. e.id, e.label), icon = e.icon }
        byId[e.id] = e
    end
    for _, b in ipairs(BASE_ACTIONS) do
        if ctx.opt(b.opt) then addEntry(b) end
    end
    if ctx.getState("openaiKey__validated", false) == true then
        for _, ai in ipairs(AI_ACTIONS) do
            if ctx.opt(ai.opt) then addEntry(ai) end
        end
    end
    return actions, byId
end

-- Run the chosen picker `entry` against `content`: base transforms paste back
-- in place; AI entries (translate/freeAsk prompt for input first) send to
-- OpenAI. The dispatch the audit called the natural extraction.
---@param ctx Ctx
local function runEntry(ctx, content, entry)
    local id = entry.id
    if id == "lowercase" then
        pasteBack(ctx, content:lower())
    elseif id == "uppercase" then
        pasteBack(ctx, content:upper())
    elseif id == "calculate" then
        -- Evaluate as a Lua expression in a math-only sandbox (the donor used
        -- the full globals).
        local fn, loadErr = load("return " .. content, "calc", "t", { math = math })
        if not fn then
            ctx.alert(ctx.t("alert.notExpr", "Not an expression: %s", tostring(loadErr)))
            return
        end
        local okEval, result = pcall(fn)
        if not okEval then
            ctx.alert(ctx.t("alert.calcFailed", "Calculation failed: %s", tostring(result)))
            return
        end
        pasteBack(ctx, tostring(result))
    elseif id == "dictionary" then
        lookupInDict(ctx, content)
    elseif entry.translate then
        ctx.askText {
            title = ctx.t("prompt.translate.title", "Translate to which language?"),
            placeholder = ctx.t("prompt.translate.ph", "e.g. French, 日本語"),
            onSubmit = function(lang)
                if lang and lang ~= "" then
                    -- gsub with a function replacement so a "%" in the language
                    -- can't be read as a capture reference.
                    local tmpl = ctx.opt(entry.promptOpt)
                    openChat(ctx, entry, content, (tmpl:gsub("{lang}", function() return lang end)),
                        ctx.t("chat.translateInto", "Translate into %s", lang))
                end
            end,
        }
    elseif entry.freeAsk then
        ctx.askText {
            title = ctx.t("prompt.instruct.title", "Instruction for the selected text"),
            placeholder = ctx.t("prompt.instruct.ph", "e.g. what does this imply?"),
            onSubmit = function(prompt)
                if prompt and prompt ~= "" then openChat(ctx, entry, content, prompt, prompt) end
            end,
        }
    elseif entry.chat then
        openChat(ctx, entry, content, ctx.opt(entry.promptOpt))
    elseif entry.promptOpt then
        pasteAI(ctx, entry, content, ctx.opt(entry.promptOpt))
    end
end

-- Act on the captured selection `content`: nothing selected -> alert (prompting
-- for Accessibility if that's why); a URL opens directly; otherwise offer the
-- transform picker and dispatch the choice.
---@param ctx Ctx
local function actOnSelection(ctx, content)
    if content == "" then
        local trusted = ctx.axTrusted()
        ctx.log("nothing selected (Accessibility granted: " .. tostring(trusted) .. ")")
        if not trusted then
            ctx.axPrompt()
            ctx.alert(ctx.t("alert.axRequired",
                "Selection Actions needs the Accessibility permission to read the selection -- grant it in System Settings, then try again"))
        else
            ctx.alert(ctx.t("alert.nothingSelected", "Nothing selected"))
        end
        return
    end

    -- URL: open it directly, no picker.
    if content:lower():find("^https?://") then
        ctx.log("selection is a URL -- opened")
        ctx.openURL(content)
        return
    end

    local actions, byId = buildPicker(ctx)
    if #actions == 0 then
        ctx.log("picker empty: every action is switched off")
        ctx.alert(ctx.t("alert.noneEnabled", "No Text Actions are enabled -- turn some on in Settings"))
        return
    end

    ctx.log(string.format("picker: %d actions for a %d-byte selection", #actions, #content))
    local snippet = content:sub(1, 24)
    ctx.askChoice {
        title = ctx.t("dialog.title", "Action for [%s]", snippet),
        infos = { snippet },
        actions = actions,
        onChoose = function(choice)
            local entry = choice and byId[choice]
            ctx.log("picker: " .. (entry and entry.id or "dismissed"))
            if entry then runEntry(ctx, content, entry) end
        end,
    }
end

return {
    api         = 1,
    id          = "text_actions",

    options = {
        -- Simple popup transforms (which base actions appear in the "act on
        -- selection" picker; all on by default).
        { key = "showLowercase",   type = "bool", default = true, label = "Show lowercase",  section = "Transforms", preview = "case:lower" },
        { key = "showUppercase",   type = "bool", default = true, label = "Show UPPERCASE",  section = "Transforms", preview = "case:upper" },
        { key = "showCalculate",   type = "bool", default = true, label = "Show Calculate",  section = "Transforms", preview = "calc" },

        -- Dictionary: the toggle plus its custom-app config, paste delay, and a
        -- Test button (looks up a fixed word so the config can be verified).
        { key = "showDictionary",  type = "bool", default = true, label = "Show Dictionary", section = "Dictionary", preview = "dict" },
        { key = "dictApp", type = "appList", default = "", section = "Dictionary",
          label = "Custom dictionary app", defaultLabel = "macOS Dictionary",
          actionLabel = "Test",
          hint = "The custom app must accept a paste (Cmd+V) into its search field." },
        { key = "dictDelayMs", type = "int", default = 750, min = 100, max = 5000, section = "Dictionary",
          label = "Custom dict paste delay (ms)",
          hint = "Wait this long after the app focuses before pasting -- raise it if "
            .. "the app is slow to launch or focus." },

        -- AI: the credential + model come BEFORE the toggles so the flow reads
        -- top-down: enter key -> Validate -> the AI toggles below light up.
        -- `validate = "openai"` makes Settings render a Validate button that
        -- checks the key and fetches the available models; until it succeeds the
        -- gatedBy toggles stay grayed and ctx.getState("openaiKey__validated") is
        -- false, so the picker shows no AI entries.
        { key = "openaiKey", type = "secret", validate = "openai", section = "AI",
          label = "OpenAI API key" },
        -- The model is an enum whose choices are POPULATED by a successful
        -- validate (valuesFrom); the values here are the seed shown beforehand.
        { key = "model", type = "enum", default = "gpt-4o-mini", valuesFrom = "openaiKey", section = "AI",
          label = "OpenAI model",
          values = { "gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1", "o4-mini" } },
        -- The AI picker entries -- each grayed until the key validates (gatedBy)
        -- and only effective then (the picker is gated on the same flag). Each
        -- toggle is followed by its editable system prompt (multiline), so the
        -- user can tune what that action asks the model; the defaults come from
        -- PROMPTS above. Free ask has no prompt option (you type it each run).
        { key = "showAiRefine",    type = "bool", default = true, label = "Show AI: Refine",    gatedBy = "openaiKey", section = "AI", preview = "ai:refine" },
        { key = "aiRefinePrompt",  type = "string", multiline = true, collapsible = true, default = PROMPTS.refine, gatedBy = "openaiKey", section = "AI",
          label = "AI: Refine prompt",
          hint = "System prompt sent with the selection as the user message." },
        { key = "showAiEnrich",    type = "bool", default = true, label = "Show AI: Enrich",    gatedBy = "openaiKey", section = "AI", preview = "ai:enrich" },
        { key = "aiEnrichPrompt",  type = "string", multiline = true, collapsible = true, default = PROMPTS.enrich, gatedBy = "openaiKey", section = "AI",
          label = "AI: Enrich prompt",
          hint = "System prompt sent with the selection as the user message." },
        { key = "showAiComplete",  type = "bool", default = true, label = "Show AI: Complete",  gatedBy = "openaiKey", section = "AI", preview = "ai:complete" },
        { key = "aiCompletePrompt", type = "string", multiline = true, collapsible = true, default = PROMPTS.complete, gatedBy = "openaiKey", section = "AI",
          label = "AI: Complete prompt",
          hint = "System prompt sent with the selection as the user message." },
        { key = "showAiSummary",   type = "bool", default = true, label = "Show AI: Summary",   gatedBy = "openaiKey", section = "AI", preview = "ai:summary" },
        { key = "aiSummaryPrompt", type = "string", multiline = true, collapsible = true, default = PROMPTS.summary, gatedBy = "openaiKey", section = "AI",
          label = "AI: Summary prompt",
          hint = "System prompt sent with the selection as the user message." },
        { key = "showAiTranslate", type = "bool", default = true, label = "Show AI: Translate", gatedBy = "openaiKey", section = "AI", preview = "ai:translate" },
        { key = "aiTranslatePrompt", type = "string", multiline = true, collapsible = true, default = PROMPTS.translate, gatedBy = "openaiKey", section = "AI",
          label = "AI: Translate prompt",
          hint = "{lang} is replaced by the language you enter when you run it." },
        { key = "showAiFreeAsk",   type = "bool", default = true, label = "Show AI: Free ask",  gatedBy = "openaiKey", section = "AI", preview = "ai:freeask" },
    },

    -- Settings "Test" buttons: each maps an option key to a handler run with the
    -- feature's ctx (the option declares actionLabel to render the button). The
    -- dictApp test looks a fixed word up so the user can confirm their app +
    -- delay are right without selecting text first.
    optionActions = {
        dictApp = function(ctx) lookupInDict(ctx, "peace") end,
    },

    actions = {
        {
            id = "quick_open",
            label = "Act on selected text",
            description = "Copies the selection, then offers a menu: open URLs, change "
                .. "case, calculate, look it up in a dictionary, or (with a key) run it "
                .. "through AI -- edits paste back in place, answers open in a window "
                .. "you can keep asking in.",
            defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "o" },
            mnemonic = "O — act On the selection",
            ---@param ctx Ctx
            run = function(ctx)
                -- Capture the selection (cmd+C), then act on it once it has
                -- reached the clipboard. The body lives in the module-level
                -- helpers above (pasteBack / requestAI / buildPicker / runEntry /
                -- actOnSelection) -- this closure is just the copy + handoff.
                ctx.keyStroke({ "cmd" }, "c")
                ctx.afterSeconds(COPY_SETTLE_SECONDS, function()
                    local raw = ctx.pasteboardRead()
                    actOnSelection(ctx, raw and raw:match("^%s*(.-)%s*$") or "")
                end)
            end,
        },
    },
}
