// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hammerdeck",
    platforms: [.macOS(.v13)],
    targets: [
        // Vendored Lua 5.4 compiled as a C target. This is the embedded engine.
        .target(
            name: "CLua",
            cSettings: [
                .define("LUA_USE_MACOSX"),        // enables POSIX + dlopen on macOS
                .headerSearchPath("include"),     // public API headers (lua.h, ...)
            ]
        ),
        // A tiny ObjC shim for macOS Notification Center delivery via the
        // permission-free (but deprecated) NSUserNotification API. Isolated in
        // ObjC so the deprecation `#pragma` keeps the Swift build warning-free.
        // Only the native seam (Native+Notifications.swift) imports it.
        .target(name: "HammerdeckNotify"),
        // Everything real lives here so the integration tests can import it:
        // the Swift<->Lua bridge, the native seam, panels, and the config UI.
        //
        // Co-location layout: this target roots at `app/`, the SAME tree that
        // holds the Lua payload (`app/platform/*.lua`, `app/features/<id>/*.lua`,
        // `app/hammerdeck.lua`). A SwiftPM target compiles ONE subtree, so the
        // host Swift lives under it too -- `app/platform/swift/` for the platform,
        // `app/features/<id>/swift/` for a feature's native UI. `sources` lists
        // ONLY the Swift dirs, so just those compile -- but SwiftPM still SCANS
        // the whole `app/` subtree for resources and warns ("N unhandled files")
        // about every co-located `.lua`/`.json`. `sources` limits compilation,
        // NOT the resource scan, so we must also `exclude` the Lua payload to
        // keep the build clean. (`exclude` overrides `sources`, so a broad
        // `exclude: ["features"]` would drop a feature's swift too -- list each
        // Lua-only feature dir individually, and the non-swift parts of any
        // feature that DOES have swift.) The Lua is loaded at runtime by path
        // (Boot.defaultLuaDir -> `app/`), never bundled; the warning is cosmetic
        // but we silence it. A `swift/` subfolder under a feature = "this feature
        // has native UI" at a glance.
        //
        // MAINTENANCE when adding a feature `app/features/<id>/`:
        //   - Lua-only feature -> add `"features/<id>"` to `exclude` below.
        //   - feature WITH a `swift/` -> add `"features/<id>/swift"` to `sources`
        //     AND `"features/<id>/lua"` + `"features/<id>/feature.json"` to `exclude`.
        // (Skipping the exclude just brings the harmless warning back for that feature.)
        .target(
            name: "HammerdeckKit",
            dependencies: ["CLua", "HammerdeckNotify"],
            path: "app",
            exclude: [
                "hammerdeck.lua",
                "loader.lua",
                "i18n",                  // localization catalogs (loaded at runtime by path)
                "platform/lua",
                "features/bing_daily",
                "features/break_reminder",
                "features/clipboard_history",
                "features/command_palette",
                "features/confirm_shortcut",
                "features/count_down",
                "features/display_off",
                "features/insert_datetime",
                "features/locate_pointer",
                "features/notify_on_trigger",
                "features/password_generator",
                "features/plain_paste",
                "features/pointer_follows_window",
                "features/site_switcher",
                "features/sleep_schedule",
                "features/tab_switcher",
                "features/text_actions",
                "features/usage_stats/lua",
                "features/usage_stats/feature.json",
                "features/usage_stats/i18n",
                "features/window_deck/lua",
                "features/window_deck/feature.json",
                "features/window_deck/i18n",
                "features/window_grid",
                "features/window_modal",
                "features/window_rewind",
                "features/window_snap",
                "features/window_stack/lua",
                "features/window_stack/feature.json",
                "features/window_stack/i18n",
                "features/window_switcher",
            ],
            sources: [
                "platform/swift",
                "features/usage_stats/swift",
                "features/window_deck/swift",
                "features/window_stack/swift",
            ]
        ),
        // Thin launcher: top-level code only (executable targets cannot be
        // cleanly imported by test targets, so they stay logic-free).
        .executableTarget(
            name: "Hammerdeck",
            dependencies: ["HammerdeckKit"]
        ),
        // Integration tests against the REAL bridge (no fake adapter): boot the
        // Lua platform in-process and exercise Lua<->Swift<->macOS end to end.
        .testTarget(
            name: "HammerdeckTests",
            dependencies: ["HammerdeckKit"]
        ),
    ]
)
