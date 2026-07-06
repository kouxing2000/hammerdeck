-- test/cases/json_codec.lua -- pure codec unit tests for platform.json: the decoder
-- (nested shapes, numbers, string escapes incl. surrogate pairs, malformed/trailing-garbage
-- rejection) and the __jsontype array-vs-object tags that both json.lua and the Swift
-- bridge honor symmetrically (decisive for empty tables, and the loud rejection of a table
-- that mixes array entries with string keys).
--
-- Migrated from the json half of run.lua T18 (RUN_LUA_SPLIT_SPEC Phase 2). Split out from
-- bing_daily (its monolith bunkmate, which consumed the decoder) into its own leaf-util
-- case, mirroring windows_geometry: platform.json is a leaf util, not a feature, so these
-- assertions call it directly -- no feature, no adapter handles.

return {
    id = "json_codec",
    ---@param t Harness
    run = function(t)
        local ok = t.ok
        local jsonlib = require("platform.json")
        local jd = jsonlib.decode
        ok(jd('{"a":1,"b":[true,false,"x"],"c":{"d":-2.5e2}}').c.d == -250, "json: nested object/array/number")
        ok(jd('[1,2,3]')[3] == 3, "json: plain array")
        ok(jd('"a\\"b\\n\\u0041\\ud83d\\ude00"') == 'a"b\nA\240\159\152\128', "json: escapes incl. surrogate pair")
        ok(jd('  true  ') == true, "json: bare literal with whitespace")
        ok(jd('{"a":}') == nil, "json: malformed -> nil")
        ok(jd('[1,2,]') == nil, "json: trailing comma -> nil")
        ok(jd('{"a":1} x') == nil, "json: trailing garbage -> nil")

        -- __jsontype tags: array vs object disambiguation (decisive for empty tables),
        -- honored symmetrically by encode (the Swift bridge reads the same metafield).
        local je = jsonlib.encode
        ok(je(jsonlib.asObject({})) == "{}", "json: empty object tag encodes as {}")
        ok(je(jsonlib.asArray({})) == "[]", "json: empty array tag encodes as []")
        ok(je({}) == "[]", "json: untagged empty table stays [] (back-compat default)")
        ok(je(jd("{}")) == "{}", "json: decode->encode keeps an empty object")
        ok(je(jd("[]")) == "[]", "json: decode->encode keeps an empty array")
        ok(je(jsonlib.asObject({ a = 1 })) == '{"a":1}', "json: non-empty object unchanged by tag")
        ok(select(2, je({ 1, 2, x = "oops" })) ~= nil,
            "json: a mixed array+string-key table is rejected loudly, not silently dropped")
        -- The command_palette legacy case: a map persisted as "[]" decodes array-tagged;
        -- re-tagging it object lets string keys be added and re-encoded without error.
        local relabelled = jsonlib.asObject(jd("[]") --[[@as table]]); relabelled.k = 1
        ok(je(relabelled) == '{"k":1}', "json: asObject re-tags a decoded [] so a map built on it is safe")
    end,
}
