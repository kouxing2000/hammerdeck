-- test/run.lua -- headless platform + feature test RUNNER (against the fake adapter).
--
-- Run from the repo root:  lua test/run.lua            (all cases)
--                          lua test/run.lua <id>       (one case, by id)
--                          lua test/run.lua --shuffle  (randomized order)
--
-- Every test BODY now lives in a hermetic case file under test/cases/ (RUN_LUA_SPLIT_SPEC,
-- completed): a per-feature case is test/cases/<id>.lua; cross-cutting integration lives
-- under test/cases/_integration/, with the rules-engine and platform-lifecycle clusters in
-- their own rules/ and platform/ subfolders. Each case returns
-- { id, run = function(t) ... end, tags? }, owns its fixtures, and runs order-independently.
-- This file is a PURE RUNNER: discover the cases, run each in a fresh world, and assert a
-- clean handle count after every one.
--
-- Shared setup, the `ok`/helpers, the single assertion counter, the per-case world reset
-- (freshWorld), and discover() all live in test/harness.lua. Bootstrap package.path here so
-- `require` finds harness under test/; harness itself installs the co-located loader + seam
-- and pins the deterministic clock.
package.path = "app/?.lua;app/?/init.lua;test/?.lua;" .. package.path
local harness = require("harness")
local t = harness.t
local ok, fake, registry = t.ok, t.fake, t.registry

-- Migration map -- which original run.lua T-section became which case file.
-- Per-feature cases (test/cases/<id>.lua):
--   T3/T21 -> window_switcher      T4   -> sleep_schedule       T5   -> break_reminder
--   T12    -> display_off          T13  -> plain_paste          T13c -> password_generator
--   T13d   -> insert_datetime      T16  -> count_down           T17  -> locate_pointer
--   T18    -> json_codec + bing_daily                           T20/T32 -> usage_stats
--   T22    -> text_actions         T23  -> site_switcher        T24/T24p -> window_snap
--   T24b   -> pointer_follows_window   T24r -> window_rewind     T25  -> window_modal
--   T25c/d -> windows_geometry     T25e -> window_grid          T26  -> tab_switcher
--   T25e-store/T25f -> window_deck_pure + window_deck           T28  -> clipboard_history
--   T29    -> command_palette
-- Cross-cutting integration (test/cases/_integration/):
--   T13c2 -> describe_localization   T30 -> fire_time_errors    T33 -> manifest_page
--   T31   -> modal_repeat + shortcut_advisories
-- Rules-engine cluster (test/cases/_integration/rules/, Phase 3): T34..T41 -> rules_*.lua.
-- Platform-lifecycle core (test/cases/_integration/platform/, Block A):
--   T0   -> adapter_surface_parity   T0b  -> i18n_catalog        T1/T6/T7 -> catalog_describe
--   T2 + validate tail -> manifest_contract               T7b  -> schedule_descriptor
--   T7c  -> notify_on_automated_run
--   T7d  -> confirm_shortcut_flash   T7f  -> confirm_action      T7g  -> modal_sticky_twin
--   T7e  -> default_enabled          T8   -> re_enable           T9   -> feature_quarantine
--   T10  -> trigger_rebind           T11  -> hot_reload          T14  -> feature_autodiscovery
--   T15  -> multi_action             T19  -> chord_triggers      T19b -> hyper_legend
--   T25g -> shortcut_collisions      T27  -> run_action

-- Run each migrated hermetic case in a fresh world; the freshWorld() before it and the
-- handle tripwire after keep it isolated -- every case is checked, a strictly stronger
-- guarantee than the old monolith's scattered positional liveHandles checks. `arg` may
-- name one case (narrowing the loop) or pass --shuffle (the order-independence self-check).
local cases = harness.discover("test/cases", arg)
-- Refuse a false green. An empty discovery -- a broken test/cases path, a searcher
-- regression, or a bare `<id>` arg that matches nothing -- would otherwise run zero
-- cases, print "OK -- 0 assertions passed", and exit 0: an all-clear that silently
-- tested nothing. `#cases > 0` is a safe invariant (there is always at least one case,
-- and a real narrow matches at least the case it names).
local narrowed
for _, a in ipairs(arg or {}) do
    if a:sub(1, 2) ~= "--" then narrowed = a end
end
assert(#cases > 0, "no test cases discovered under test/cases"
    .. (narrowed and (" matching '" .. narrowed .. "'") or "")
    .. " -- refusing to report a false green")

for _, case in ipairs(cases) do
    harness.freshWorld()
    case.run(t)
    ok(fake.liveHandles == 0 and registry.liveHandleCount() == 0,
        case.id .. ": leaked no native handles")
end

harness.report()
