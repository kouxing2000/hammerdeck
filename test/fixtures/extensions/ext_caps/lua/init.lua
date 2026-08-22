-- test fixture: a USER EXTENSION that MIS-DECLARES its capabilities, so
-- registry.validateExtension has both directions to find. Its feature.json
-- claims "power" (which nothing here uses) while the code below reaches the
-- network (which it never declares). Deliberately wrong -- do not "fix" it.
return {
    api = 1,
    id  = "ext_caps",
    action = function(ctx)
        ctx.httpGet("https://example.invalid/ping", function() end)
    end,
}
