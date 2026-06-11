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
        .target(
            name: "HammerdeckKit",
            dependencies: ["CLua"]
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
