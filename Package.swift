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
        // The native host: owns the Swift<->Lua bridge and (later) the menubar UI.
        .executableTarget(
            name: "Hammerdeck",
            dependencies: ["CLua"]
        ),
    ]
)
