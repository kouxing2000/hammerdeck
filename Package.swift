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
        // Everything real lives here so the integration tests can import it:
        // the Swift<->Lua bridge, the native seam, panels, and the config UI.
        //
        // Co-location layout: this target roots at `app/`, the SAME tree that
        // holds the Lua payload (`app/platform/*.lua`, `app/features/<id>/*.lua`,
        // `app/hammerdeck.lua`). A SwiftPM target compiles ONE subtree, so the
        // host Swift lives under it too -- `app/platform/swift/` for the platform,
        // `app/features/<id>/swift/` for a feature's native UI. `sources` lists
        // ONLY the Swift dirs, so the co-located `.lua` files are simply not part
        // of the target (no "unhandled resource" diagnostic). The Lua is loaded
        // at runtime by path (Boot.defaultLuaDir -> `app/`), never bundled. A
        // `swift/` subfolder under a feature = "this feature has native UI" at a
        // glance; add the feature's `swift` dir here when it grows one.
        .target(
            name: "HammerdeckKit",
            dependencies: ["CLua"],
            path: "app",
            sources: [
                "platform/swift",
                "features/usage_stats/swift",
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
