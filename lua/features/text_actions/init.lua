-- features/text_actions
--
-- Act on the currently SELECTED text in any app (ported from myHammerSpoon
-- modules/input/textActions.lua): synthesize cmd+C to capture the selection,
-- then either open it (URLs) or offer a picker of transforms that paste the
-- result back over the selection (cmd+V).
--
-- Actions: open URL, lowercase, UPPERCASE, calculate (evaluates the selection
-- as a Lua expression in a math-only sandbox), Dictionary (the macOS Dictionary
-- via dict:// by default; a custom app via launchOrFocus+paste+return if configured),
-- and -- once an OpenAI key is entered AND validated in Settings -- six AI
-- actions (refine, enrich, complete, translate, summary, freeAsk) that send the
-- selection to OpenAI chat completions and paste the reply back. The AI entries
-- stay hidden until the key validates (ctx.getState("openaiKey__validated")).
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
-- hide the ones they never use (all default on). The label is also the value
-- matched in onChoose below, so keep them in sync.
local BASE_ACTIONS = {
    { label = "Dictionary", opt = "showDictionary" },
    { label = "lowercase",  opt = "showLowercase" },
    { label = "UPPERCASE",  opt = "showUppercase" },
    { label = "Calculate",  opt = "showCalculate" },
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
    summary = "Summarize the following text concisely in its own language. "
        .. "Return only the summary.",
    translate = "Translate the following into {lang}. Return only the translation.",
}

-- AI picker entries: each maps a label to its `opt` toggle and (except free ask)
-- a `promptOpt` -- the option key holding its editable system prompt. translate
-- and freeAsk are handled specially (they prompt for input first): translate
-- still has an editable prompt (with a {lang} token); free ask's prompt IS the
-- user's run-time instruction, so it has no promptOpt. AI entries appear only
-- when BOTH the key is validated and the entry's toggle is on.
local AI_ACTIONS = {
    { label = "AI: Refine",    opt = "showAiRefine",    promptOpt = "aiRefinePrompt" },
    { label = "AI: Enrich",    opt = "showAiEnrich",    promptOpt = "aiEnrichPrompt" },
    { label = "AI: Complete",  opt = "showAiComplete",  promptOpt = "aiCompletePrompt" },
    { label = "AI: Summary",   opt = "showAiSummary",   promptOpt = "aiSummaryPrompt" },
    { label = "AI: Translate", opt = "showAiTranslate", promptOpt = "aiTranslatePrompt", translate = true },
    { label = "AI: Free ask",  opt = "showAiFreeAsk",   freeAsk = true },
}

-- Look `word` up in the dictionary: the user's custom app (launch/focus it --
-- the original HS launchOrFocus, so it opens even if quit -- then clear the
-- field, PASTE the word, and search; paste is more reliable than typing, esp.
-- for CJK) or, when none is configured, the macOS Dictionary via dict://. Shared
-- by the Dictionary action and the Settings "Test" button.
local function lookupInDict(ctx, word)
    local app = ctx.opt("dictApp")   -- a bundle id, or "" for macOS Dictionary
    if app and app ~= "" then
        if not ctx.launchOrFocusApp(app) then
            ctx.alert("Could not open the dictionary app -- re-pick it in Settings")
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

return {
    api         = 1,
    id          = "text_actions",
    name        = "Text Actions",
    description = "Act on the selected text anywhere: open URLs, change case, "
        .. "calculate, look up in the macOS Dictionary, and -- with an OpenAI "
        .. "key -- refine/translate/summarize via AI. Results paste back in place.",
    version     = "1.1.0",
    category    = "productivity",

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
                .. "through AI -- the result pastes back in place.",
            defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "o" },
            mnemonic = "O — act On the selection",
            run = function(ctx)
                ctx.keyStroke({ "cmd" }, "c")
                ctx.afterSeconds(COPY_SETTLE_SECONDS, function()
                    local raw = ctx.pasteboardRead()
                    local content = raw and raw:match("^%s*(.-)%s*$") or ""
                    if content == "" then
                        if not ctx.axTrusted() then
                            ctx.axPrompt()
                            ctx.alert("Selection Actions needs the Accessibility "
                                .. "permission to read the selection -- grant it "
                                .. "in System Settings, then try again")
                        else
                            ctx.alert("Nothing selected")
                        end
                        return
                    end

                    -- URL: open it directly, no picker.
                    if content:lower():find("^https?://") then
                        ctx.openURL(content)
                        return
                    end

                    local snippet = content:sub(1, 24)
                    local function pasteBack(text)
                        ctx.pasteboardWrite(text)
                        ctx.keyStroke({ "cmd" }, "v")
                    end

                    -- Send `content` to OpenAI with `systemPrompt`; paste the reply.
                    local function askAI(systemPrompt)
                        local key = ctx.secret("openaiKey")
                        if not key or key == "" then
                            ctx.alert("Set an OpenAI API key in Settings first")
                            return
                        end
                        local body = json.encode(json.asObject({
                            model = ctx.opt("model"),
                            messages = json.asArray({
                                json.asObject({ role = "system", content = systemPrompt }),
                                json.asObject({ role = "user",   content = content }),
                            }),
                        }))
                        ctx.httpPost(OPENAI_URL, {
                            ["Content-Type"]  = "application/json",
                            ["Authorization"] = "Bearer " .. key,
                        }, body, function(status, respBody)
                            if status ~= 200 or not respBody then
                                ctx.alert("AI request failed (" .. tostring(status) .. ")")
                                return
                            end
                            local doc = json.decode(respBody)
                            local msg = doc and doc.choices and doc.choices[1]
                                and doc.choices[1].message
                            local result = msg and msg.content
                            if not result then
                                ctx.alert("AI returned no result")
                                return
                            end
                            pasteBack((result:gsub("^%s*(.-)%s*$", "%1")))
                        end)
                    end

                    -- Build the action list from the enabled toggles: base
                    -- transforms, plus AI entries only once the key has been
                    -- VALIDATED in Settings (the host sets this flag on a
                    -- successful Validate; cleared when the key changes) AND the
                    -- entry's toggle is on. An unvalidated key shows no AI noise.
                    local actions = {}
                    for _, b in ipairs(BASE_ACTIONS) do
                        if ctx.opt(b.opt) then actions[#actions + 1] = b.label end
                    end
                    local validated = ctx.getState("openaiKey__validated", false) == true
                    if validated then
                        for _, ai in ipairs(AI_ACTIONS) do
                            if ctx.opt(ai.opt) then actions[#actions + 1] = ai.label end
                        end
                    end
                    if #actions == 0 then
                        ctx.alert("No Text Actions are enabled -- turn some on in Settings")
                        return
                    end

                    ctx.askChoice {
                        title = "Action for [" .. snippet .. "]",
                        infos = { snippet },
                        actions = actions,
                        onChoose = function(choice)
                            if not choice then return end
                            if choice == "lowercase" then
                                pasteBack(content:lower())
                                return
                            elseif choice == "UPPERCASE" then
                                pasteBack(content:upper())
                                return
                            elseif choice == "Calculate" then
                                -- Evaluate as a Lua expression in a math-only
                                -- sandbox (the donor used the full globals).
                                local fn, loadErr = load("return " .. content,
                                    "calc", "t", { math = math })
                                if not fn then
                                    ctx.alert("Not an expression: " .. tostring(loadErr))
                                    return
                                end
                                local okEval, result = pcall(fn)
                                if not okEval then
                                    ctx.alert("Calculation failed: " .. tostring(result))
                                    return
                                end
                                pasteBack(tostring(result))
                                return
                            elseif choice == "Dictionary" then
                                lookupInDict(ctx, content)
                                return
                            end

                            -- AI entries (present only when a key is set).
                            for _, ai in ipairs(AI_ACTIONS) do
                                if choice == ai.label then
                                    if ai.translate then
                                        ctx.askText {
                                            title = "Translate to which language?",
                                            placeholder = "e.g. French, 日本語",
                                            onSubmit = function(lang)
                                                if lang and lang ~= "" then
                                                    -- gsub with a function replacement so a
                                                    -- "%" in the language can't be read as a
                                                    -- capture reference.
                                                    local tmpl = ctx.opt(ai.promptOpt)
                                                    askAI((tmpl:gsub("{lang}", function() return lang end)))
                                                end
                                            end,
                                        }
                                    elseif ai.freeAsk then
                                        ctx.askText {
                                            title = "Instruction for the selected text",
                                            placeholder = "e.g. make this more formal",
                                            onSubmit = function(prompt)
                                                if prompt and prompt ~= "" then askAI(prompt) end
                                            end,
                                        }
                                    else
                                        askAI(ctx.opt(ai.promptOpt))
                                    end
                                    return
                                end
                            end
                        end,
                    }
                end)
            end,
        },
    },
}
