-- features/clipboard_history
--
-- Clipboard history (replaces the donor's ClipboardTool spoon -- the LAST
-- functional reason Hammerspoon had to keep running). A service polls the
-- pasteboard (changeCount, donor's 0.8s cadence) and records TEXT entries;
-- the "show" action opens a searchable chooser -- selecting an entry puts it
-- on the clipboard and (option, donor's paste_on_select) pastes it.
--
-- Privacy, donor parity: entries marked Concealed/Transient by their source
-- (password managers, text expanders -- the nspasteboard.org convention) are
-- NEVER recorded; the check happens via pasteboardInfo BEFORE the contents
-- are read. History persists to <dataDir>/clipboard_history/history.json
-- under the aligned storage policy (plaintext + FileVault + 0700).
--
-- Text only (the donor optionally handled images; not ported). Entries cap
-- at 5000 chars, donor's max_entry_size. Default trigger is Hyper+H
-- (cmd+alt+ctrl+h -- "H" for History, a right-hand key).

local POLL_SECONDS    = 0.8     -- donor frequency
local MAX_ENTRY_CHARS = 5000    -- donor max_entry_size (truncate, keep)
local PASTE_SETTLE    = 0.15    -- let the chooser close before cmd+v

local json = require("platform.json")

local shared = {}

local function start(ctx)
    local st = {
        history = {},      -- newest first, plain strings
        lastChange = nil,  -- pasteboard changeCount at the last poll
        chooser = nil,
    }
    shared.st = st

    local dataDir = ctx.dataDir() .. "/clipboard_history"
    local histPath = dataDir .. "/history.json"

    local function save()
        local s = json.encode(st.history)
        if s then
            ctx.mkdir(dataDir)
            ctx.fileWrite(histPath, s)
        end
    end

    local function load()
        local body = ctx.fileRead(histPath)
        local doc = body and json.decode(body) or nil
        if type(doc) == "table" then
            for _, e in ipairs(doc) do
                if type(e) == "string" then st.history[#st.history + 1] = e end
            end
        end
    end

    -- Record `text`: dedup moves an existing entry to the front; cap size.
    local function record(text)
        if not text or text == "" then return end
        if #text > MAX_ENTRY_CHARS then text = text:sub(1, MAX_ENTRY_CHARS) end
        for i, e in ipairs(st.history) do
            if e == text then table.remove(st.history, i); break end
        end
        table.insert(st.history, 1, text)
        local cap = ctx.opt("historySize")
        while #st.history > cap do table.remove(st.history) end
        save()
    end

    local function poll()
        local info = ctx.pasteboardInfo()
        if not info or info.change == st.lastChange then return end
        st.lastChange = info.change
        if info.concealed then return end   -- password managers etc: never record
        record(ctx.pasteboardRead())
    end

    -- One-line preview for the chooser row.
    local function preview(text)
        local line = text:match("^[^\n]*") or text
        if #line > 70 then line = line:sub(1, 70) .. "…" end
        if line ~= text then
            return line, (#text >= 1000 and math.floor(#text / 1000) .. "k chars"
                          or #text .. " chars")
        end
        return line, nil
    end

    function st.show()
        if #st.history == 0 then
            ctx.alert(ctx.t("alert.empty", "Clipboard history is empty"))
            return
        end
        if not st.chooser then
            st.chooser = ctx.chooser {
                searchSubText = false,
                onSelect = function(choice)
                    if not choice then return end
                    -- Resolve against the SNAPSHOT shown in this chooser, not
                    -- the live history: the 0.8s poll keeps recording while
                    -- the chooser is open, and a copy made meanwhile would
                    -- shift every index (and paste the wrong entry).
                    local text = st.shown and st.shown[choice.index]
                    if not text then return end
                    record(text)                 -- selection bumps it to front
                    ctx.pasteboardWrite(text)
                    if ctx.opt("pasteOnSelect") then
                        ctx.afterSeconds(PASTE_SETTLE, function()
                            ctx.keyStroke({ "cmd" }, "v")
                        end)
                    end
                end,
            }
        end
        local choices = {}
        st.shown = {}
        for i, e in ipairs(st.history) do
            st.shown[i] = e
            local text, sub = preview(e)
            -- Leading glyph so entries are scannable at a glance: a URL reads as
            -- a link, everything else as plain text.
            local icon = e:lower():find("^%s*https?://") and "symbol:link" or "symbol:doc.plaintext"
            choices[#choices + 1] = { text = text, subText = sub, index = i, image = icon }
        end
        st.chooser.setPlaceholder(ctx.t("chooser.placeholder", "Clipboard history"))
        st.chooser.setChoices(choices)
        st.chooser.setQuery(nil)
        st.chooser.show()
    end

    -- Wire up.
    load()
    local info = ctx.pasteboardInfo()
    st.lastChange = info and info.change or nil   -- don't re-record the current clip
    ctx.everySeconds(POLL_SECONDS, poll)
    ctx.log("started (" .. #st.history .. " entries)")
end

return {
    api         = 1,
    id          = "clipboard_history",
    -- The default "Paste on select" path synthesizes Cmd+V (keyStroke -> CGEvents),
    -- which the OS silently drops without the Accessibility grant -- so it needs
    -- the same precondition badge as the other keystroke-synthesizing features.

    options = {
        { key = "historySize", type = "int", default = 100, min = 10, max = 500,
          label = "Entries to keep" },
        { key = "pasteOnSelect", type = "bool", default = true,
          label = "Paste on select" },
    },

    start = start,

    actions = {
        { id = "show", label = "Show clipboard history",
          defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "h" },
          mnemonic = "H for History",
          run = function(ctx)
              if shared.st then shared.st.show() end
          end },
    },

    stop = function(ctx)
        shared.st = nil
    end,
}
