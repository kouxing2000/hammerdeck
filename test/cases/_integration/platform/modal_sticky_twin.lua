-- test/cases/_integration/platform/modal_sticky_twin.lua -- the modal sticky-twin exception (the window_grid Hyper+4 -> cell 4
-- fix) -- a modal twins each bare key under the leader mods; the entry key is
-- excluded by default (so a toggle re-press exits), but stickyExceptKey=false
-- twins every key so Hyper+<entry> places that cell instead of re-entering.
--
-- Migrated from run.lua T7g (RUN_LUA_SPLIT_SPEC Block A: platform-lifecycle core).
-- Integration (platform core, not a single feature under test). Hermetic:
-- freshWorld() gives a pristine catalog + rules singleton + fake world before the
-- case, and the runner's per-case handle tripwire proves nothing leaks.

return {
    id = "modal_sticky_twin",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, fake = t.ok, t.fake

        do
            local modal = require("platform.modal")
            local HYPER = { "cmd", "alt", "ctrl" }
            local function twinBound(key)
                for _, h in ipairs(fake.hotkeys) do
                    if not h.stopped and h.key == key and h.mods and #h.mods == 3 then return true end
                end
                return false
            end

            -- Toggle-mode default: the entry key ("4") is excluded from twinning.
            local hExcl = modal.enter({
                stickyMods = HYPER, stickyExceptKey = "4",
                bindings = { { key = "1", fn = function() end }, { key = "4", fn = function() end } },
            })
            ok(twinBound("1") and not twinBound("4"),
                "stickyExceptKey excludes the entry key's sticky twin (Hyper+1 yes, Hyper+4 no)")
            hExcl.stop()

            -- window_grid's fix: exception OFF -> every bare key twins, so Hyper+4 lands cell 4.
            local hAll = modal.enter({
                stickyMods = HYPER, stickyExceptKey = false,
                bindings = { { key = "1", fn = function() end }, { key = "4", fn = function() end } },
            })
            ok(twinBound("1") and twinBound("4"),
                "stickyExceptKey=false twins every bare key (Hyper+4 places cell 4, no re-enter)")
            hAll.stop()
        end
    end,
}
