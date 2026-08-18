-- test fixture: a minimal USER EXTENSION (loaded from a folder OUTSIDE
-- app/features via the hammerdeck.extensionsDir mechanism). Same manifest
-- contract as a built-in feature; identity/presentation live in the sibling
-- feature.json, translations in i18n/zh-Hans.json -- so the extension test can
-- prove the feature.json overlay and the i18n catalog both resolve against
-- THIS folder, not <appdir>/features/ext_probe.
return {
    api = 1,
    id  = "ext_probe",
    defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "shift" }, key = "9" },
    action = function(ctx)
        ctx.notify("Ext Probe", "extension action fired")
    end,
}
