-- test/cases/_integration/describe_localization.lua -- describe() localizes feature
-- metadata (names, descriptions, action labels, enum labels) via per-feature catalogs,
-- applied at CALL time so switching locale re-describes without touching the views.
--
-- Migrated from run.lua T13c2 (RUN_LUA_SPLIT_SPEC). Integration: it spans several
-- features' i18n catalogs. Registers its own window_switcher / plain_paste /
-- password_generator so describe() has them; the i18n.tFeature runtime lookups read
-- per-feature catalogs straight from disk (registration-independent). freshWorld()
-- resets the locale to "en" before every case, so this one need not restore it for
-- isolation -- the trailing configure(en) is a real assertion (describe() returns to
-- English), not cleanup.

return {
    id = "describe_localization",
    tags = { "integration" },
    ---@param t Harness
    run = function(t)
        local ok, registry = t.ok, t.registry
        registry.register(require("features.window_switcher"))
        registry.register(require("features.plain_paste"))
        registry.register(require("features.password_generator"))

        local i18n = require("platform.i18n")
        i18n.configure({ locale = "zh-Hans", appdir = "app" })

        local byId = {}
        for _, d in ipairs(registry.describe()) do byId[d.id] = d end

        ok(byId.window_switcher and byId.window_switcher.name == "窗口切换器",
            "describe() localizes a feature name")
        ok(byId.plain_paste and byId.plain_paste.description
            and byId.plain_paste.description:find("无格式", 1, true) ~= nil,
            "describe() localizes a feature description")

        local mainAction
        for _, a in ipairs(byId.plain_paste.actions) do
            if a.id == "main" then mainAction = a end
        end
        ok(mainAction and mainAction.label == "粘贴为纯文本",
            "describe() localizes a per-action label")

        local modeOpt
        for _, o in ipairs(byId.plain_paste.options) do
            if o.key == "mode" then modeOpt = o end
        end
        ok(modeOpt and modeOpt.label == "转换", "describe() localizes an option label")
        ok(modeOpt and modeOpt.labels[1] == "纯文本" and modeOpt.labels[2] == "换行转逗号",
            "describe() localizes enum value labels (parallel to values)")

        -- The single-action sugar synthesizes the action's label FROM the feature name
        -- (manifest.lua), and register() overlays feature.json BEFORE validate -- so the
        -- stored label is the ENGLISH name. It must still describe as the LOCALIZED name:
        -- a single-action feature IS its feature. This used to assert the opposite --
        -- "Password Generator" -- codifying the leak that put an English label in an
        -- otherwise-Chinese menubar (StatusBar renders action.label). password_generator
        -- ships no action.main.label key, and needs none: the name IS the label.
        ok(byId.password_generator and byId.password_generator.name == "密码生成器"
            and byId.password_generator.actions[1].label == "密码生成器",
            "describe() localizes a sugar action's label via the feature name")

        -- Per-field fallback still holds where a field is genuinely its own: an action
        -- with a DECLARED label and no translation keeps its English source. (No shipped
        -- feature can show this any more -- i18n_parity.lua fails the build on an
        -- untranslated string -- so prove it on a throwaway manifest with no catalog.)
        registry.register({ api = 1, id = "loc_probe", name = "Loc Probe",
            actions = { { id = "go", label = "Do The Thing", run = function() end } } })
        local probe
        for _, d in ipairs(registry.describe()) do
            if d.id == "loc_probe" then probe = d end
        end
        ok(probe and probe.actions[1].label == "Do The Thing",
            "describe() falls back per-field to inline English for an untranslated declared label")

        -- Phase 3: runtime strings (the ctx.t call sites in features) resolve from
        -- the SAME per-feature catalogs, including interpolation placeholders.
        ok(i18n.tFeature("clipboard_history", "alert.empty", "x") == "剪贴板历史为空",
            "runtime ctx.t key resolves (clipboard_history alert)")
        ok(i18n.tFeature("text_actions", "alert.nothingSelected", "x") == "没有选中内容",
            "runtime ctx.t key resolves (text_actions alert)")
        ok(string.format(i18n.tFeature("count_down", "notify.up.title", "Time (%d min) is up!"), 5)
            == "时间 (5 分钟) 到了！",
            "runtime ctx.t key resolves with interpolation (count_down notify)")

        -- back to the source language: describe() re-reads as English immediately.
        i18n.configure({ locale = "en" })
        local backToEn
        for _, d in ipairs(registry.describe()) do
            if d.id == "window_switcher" then backToEn = d.name end
        end
        ok(backToEn == "Window Switcher",
            "describe() returns inline English when the locale resets to en")
    end,
}
