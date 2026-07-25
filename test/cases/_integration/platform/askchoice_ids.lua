-- test/cases/_integration/platform/askchoice_ids.lua -- askChoice hands back a
-- STABLE id, never the display label (CODE-12).
--
-- The bridge has always returned the chosen INDEX; adapter.askChoice used to map
-- it into the label before calling onChoose, which forced every caller to
-- dispatch on translated text -- either `if choice == someLabel` or a private
-- label->entry map. That is silent when it breaks, in three ways this case pins:
--
--   1. two rows whose translations COLLIDE become indistinguishable (a
--      label-keyed map keeps only the last, so the wrong action runs);
--   2. a label that interpolates a value (sleep_schedule's "Snooze N minutes
--      (until HH:MM)") is a different string on nearly every call;
--   3. a row list whose membership is conditional shifts every later index.
--
-- None of the three raises. The point of returning an id is that the whole class
-- stops being representable, so this case asserts the CONTRACT rather than any
-- one feature's behavior -- a future caller gets the guarantee for free.

-- NOTE ON WHAT THIS GUARDS. `require("platform.adapter")` is the FAKE here --
-- harness.lua:14 preempts the seam -- so the section below pins the fake's
-- contract, which is what every feature test in the suite runs against. That is
-- necessary but not sufficient: the SHIPPED mapping lives in the real
-- adapter.lua, and the two are independent implementations on purpose (an
-- independent fake is what makes parity checking meaningful; sharing the code
-- would make them agree trivially and prove nothing).
--
-- So the last section loads the REAL adapter.lua against a stub `native` and
-- drives its callback with an integer index, exactly as the Swift bridge does.
-- Without it this case passes while the shipped code hands back labels -- which
-- is not hypothetical: it did, on the first run of this very test.
local adapter = require("platform.adapter")
local APPDIR = require("loader").appdir

return {
    id = "askchoice_ids",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake

        -- 1. A declared id comes back, NOT the label.
        local got, gotLabel = "unset", nil
        local h = adapter.askChoice {
            title = "t",
            actions = {
                { id = "lock", label = "Lock Screen", icon = "symbol:lock" },
                { id = "sleep", label = "System Sleep" },
            },
            onChoose = function(choice, label) got, gotLabel = choice, label end,
        }
        fake.openDialog().choose("System Sleep")     -- the user clicks the row reading this
        ok(got == "sleep", "onChoose receives the row's id, not its label")
        ok(gotLabel == "System Sleep", "the label rides along second, for logs and display")
        h.stop()

        -- 2. THE CASE THE OLD CONTRACT COULD NOT EXPRESS: two rows with the same
        --    displayed text. Under label dispatch these are one key; a label->entry
        --    map keeps whichever was added last and silently runs the wrong action.
        --    Localization makes this reachable for real -- distinct English strings
        --    can collide in another language.
        local picked = nil
        local h2 = adapter.askChoice {
            actions = {
                { id = "translate", label = "Translate" },
                { id = "translate_alt", label = "Translate" },   -- same text, different action
            },
            onChoose = function(choice) picked = choice end,
        }
        fake.openDialog().choose(2)                  -- click the SECOND row by position
        ok(picked == "translate_alt",
            "a duplicate label still dispatches to the right entry (impossible under label dispatch)")
        h2.stop()

        -- 3. No `id` declared -> the 1-based INDEX, never the label. The fallback
        --    must not quietly reinstate label dispatch for callers that omit ids.
        local plain, tabular = nil, nil
        local h3 = adapter.askChoice {
            actions = { "Alpha", "Beta" },
            onChoose = function(choice) plain = choice end,
        }
        fake.openDialog().choose("Beta")
        ok(plain == 2, "a plain-string row yields its index, not its text")
        h3.stop()

        local h4 = adapter.askChoice {
            actions = { { label = "Gamma" }, { label = "Delta" } },   -- tables, but no id
            onChoose = function(choice) tabular = choice end,
        }
        fake.openDialog().choose("Delta")
        ok(tabular == 2, "a table row without an id also yields its index, not its text")
        h4.stop()

        -- 4. Dismissal stays a single nil -- callers branch on it before any
        --    id comparison, so it must not become (nil, nil) ambiguity or a label.
        local dismissed, argc = "unset", nil
        local h5 = adapter.askChoice {
            actions = { { id = "a", label = "A" } },
            onChoose = function(choice, ...) dismissed, argc = choice, select("#", ...) end,
        }
        fake.openDialog().choose(nil)
        ok(dismissed == nil, "dismissing yields nil")
        ok(argc == 0, "dismissal passes nil ALONE -- no stale label trailing behind it")
        h5.stop()

        -- 5. The fake must refuse an unknown label rather than silently doing
        --    nothing: a test that typos a row name should fail loudly, not pass
        --    by never invoking the callback at all.
        local ran = false
        local h6 = adapter.askChoice {
            actions = { { id = "x", label = "Exists" } },
            onChoose = function() ran = true end,
        }
        local d = fake.openDialog()
        ok(not pcall(function() d.choose("No Such Row") end),
            "the fake raises on a label no row carries")
        ok(ran == false, "...and does not invoke onChoose for it")
        d.choose("Exists")
        ok(ran == true, "the real label still works after the refusal")
        h6.stop()

        ok(fake.liveHandles == 0, "every dialog released its handle")

        -- ------------------------------------------------------------------
        -- THE SHIPPED PATH. Everything above exercised the fake. Load the real
        -- adapter.lua against a stub `native` and drive the callback the way the
        -- Swift bridge does -- with a 1-based INDEX (Native+Panels.swift pushes
        -- `lua_pushinteger(L, actionIdx)`), which is the input the id mapping
        -- actually receives in production.
        -- ------------------------------------------------------------------
        local savedNative = rawget(_G, "native")
        local cap = {}
        _G.native = {
            ask_choice = function(_, _, items, cb) cap.cb, cap.items = cb, items; return 1 end,
            ask_choice_dismiss = function() end,
            stop = function() end,
        }
        -- loadfile, not require: package.loaded already holds the fake, and a
        -- fresh chunk keeps this from leaking back into the rest of the suite.
        local realAdapter = assert(loadfile(APPDIR .. "/platform/lua/adapter.lua"))()
        local okRun, err = pcall(function()
            local got, gotLabel
            realAdapter.askChoice {
                actions = {
                    { id = "lock", label = "Lock Screen", icon = "symbol:lock" },
                    { id = "sleep", label = "System Sleep" },
                },
                onChoose = function(c, l) got, gotLabel = c, l end,
            }
            ok(type(cap.cb) == "function", "real adapter handed the bridge a callback")
            ok(cap.items[1].text == "Lock Screen" and cap.items[1].image == "symbol:lock",
                "real adapter still normalizes rows to { text, image } for the panel")
            cap.cb(2)                       -- the bridge reports the chosen INDEX
            ok(got == "sleep", "REAL adapter maps the bridge's index to the row's id")
            ok(gotLabel == "System Sleep", "REAL adapter passes the label second")

            -- No id declared -> index, never the label (the fallback that would
            -- otherwise quietly reinstate label dispatch in shipped code).
            local plain
            realAdapter.askChoice {
                actions = { "Alpha", "Beta" },
                onChoose = function(c) plain = c end,
            }
            cap.cb(2)
            ok(plain == 2, "REAL adapter yields the index for a row with no id")

            -- Dismissal: nil alone, no trailing label.
            local dismissed, argc = "unset", nil
            realAdapter.askChoice {
                actions = { { id = "a", label = "A" } },
                onChoose = function(c, ...) dismissed, argc = c, select("#", ...) end,
            }
            cap.cb(nil)
            ok(dismissed == nil and argc == 0, "REAL adapter passes nil alone on dismissal")
        end)
        _G.native = savedNative             -- restore before any failure propagates
        if not okRun then error(err, 0) end
    end,
}
