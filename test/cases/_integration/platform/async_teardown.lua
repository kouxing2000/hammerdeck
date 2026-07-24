-- test/cases/_integration/platform/async_teardown.lua
--
-- "Disabled" has to mean disabled, INCLUDING for work that was already in flight.
--
-- The lifecycle hole this guards (CODE-5, fixed 2026-07-24): async seam calls
-- (http_get / http_request / download_file, the out-of-process JXA tab reads, the
-- favicon scan) pin a Lua callback on the Swift side and fire it whenever the work
-- lands. They used to be fire-and-forget, so a feature disabled mid-request still
-- got its callback and kept running -- bing_daily chains
-- httpGet -> downloadFile -> setWallpaper, so turning it off mid-chain STILL
-- changed the user's wallpaper a moment later.
--
-- They are cancelable one-shots now: each returns a handle, ctx tracks it in the
-- feature's enablement scope, and teardown stops it -- which cancels the transfer
-- and drops the pinned callback (Native+Callbacks registerOneShot/fireOneShot; the
-- fake mirrors the same gate through its own oneShot helper).
--
-- fake.deferAsync is what makes this testable at all: the fake normally calls back
-- synchronously, which cannot express "landed after teardown".

return {
    id = "async_teardown",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        local fired = {}
        local poll   -- fires one more httpGet through the LIVE ctx (set by start)
        registry.register({
            api = 1,
            id = "async_probe",
            name = "Async probe",
            -- Synthetic feature: no feature.json on disk, so it declares here.
            -- It reaches the network, downloads, and the browser's favicon DB,
            -- so it needs all three -- the capability gate denies the rest.
            capabilities = { "network", "browser" },
            start = function(ctx)
                poll = function()
                    ctx.httpGet("https://example.test/a", {}, function() end)
                end
                ctx.httpGet("https://example.test/a", {}, function(status)
                    fired[#fired + 1] = "http:" .. tostring(status)
                end)
                ctx.downloadFile("https://example.test/b", "/tmp/b", function(okDl)
                    fired[#fired + 1] = "download:" .. tostring(okDl)
                end)
                ctx.extractFavicons("/tmp/icons", { "example.test" }, function()
                    fired[#fired + 1] = "favicons"
                end)
            end,
        })
        fake.httpResponses["https://example.test/a"] = { status = 200, body = "hi" }
        fake.chromeFavicons["example.test"] = true

        -- Baseline: with delivery deferred, enabling starts three in-flight calls
        -- and nothing has come back yet.
        fake.deferAsync = true
        registry.setEnabled("async_probe", true)
        ok(#fired == 0, "deferred: no callback before delivery")
        ok(#fake.pendingAsync == 3, "three async one-shots in flight")

        -- They are tracked resources, not fire-and-forget: the scope holds them.
        ok(fake.liveHandles == 3, "in-flight async calls are live tracked handles")

        -- THE GUARD: disable while all three are in flight, then let them land.
        registry.setEnabled("async_probe", false)
        ok(fake.liveHandles == 0, "teardown released every in-flight async handle")
        local delivered = fake.deliverAsync()
        ok(delivered == 3, "all three completions were delivered to the seam")
        ok(#fired == 0,
            "callbacks landing after disable do NOT run (this is the whole point)")

        -- Sanity: the same calls DO fire normally when the feature stays enabled,
        -- so the guard above is not just "nothing ever fires".
        registry.setEnabled("async_probe", true)
        ok(#fake.pendingAsync == 3, "re-enabled: three fresh calls in flight")
        fake.deliverAsync()
        ok(#fired == 3, "callbacks run normally while the feature is enabled")
        ok(fake.liveHandles == 0, "a delivered one-shot frees its handle")

        -- A COMPLETED one-shot must retire its own scope entry, not sit there until
        -- disable. Caught in review of the original CODE-5 landing: tracking alone
        -- turned every finished request into a permanent scope entry, so a feature
        -- that polls (tab_switcher lists tabs on EVERY invocation) grew the scope
        -- without bound and liveHandleCount() reported handles long since gone.
        -- Delivery is synchronous here -- deliberately the awkward order, since the
        -- callback then runs before the handle exists (see ctx.trackOneShot).
        fake.deferAsync = false
        registry.setEnabled("async_probe", true)
        local settled = registry.liveHandleCount()   -- start()'s own three have delivered
        for _ = 1, 50 do poll() end
        ok(registry.liveHandleCount() == settled,
            "50 completed one-shots leave no dead scope entries (got "
            .. registry.liveHandleCount() .. ", expected " .. settled .. ")")

        -- ...and an IN-FLIGHT one is still held, so the retire above did not simply
        -- stop tracking them (which would silently undo the teardown guard).
        fake.deferAsync = true
        poll()
        ok(registry.liveHandleCount() == settled + 1, "an in-flight one-shot IS still tracked")
        fake.deliverAsync()
        ok(registry.liveHandleCount() == settled, "and retires once it lands")
        fake.deferAsync = false

        registry.setEnabled("async_probe", false)
        ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0,
            "clean after async teardown test")
    end,
}
