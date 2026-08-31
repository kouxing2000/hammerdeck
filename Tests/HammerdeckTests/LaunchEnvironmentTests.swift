import XCTest
@testable import HammerdeckKit

// The defect is invisible from inside the app: a terminal-started Hammerdeck
// looks and behaves normally, and only the apps IT launches carry the shell
// environment. So the tests sit on the decision -- what a GUI launch would have
// produced -- rather than on the app.
//
// They never call `normalize()`. XCTest runs every case in one process, so the
// real trim would strip `CI`, which IntegrationTests reads to gate cases.
final class LaunchEnvironmentTests: XCTestCase {

    // The env a GUI launch actually produces, measured on a bundle launched by
    // Finder.
    private let guiEnv = [
        "COMMAND_MODE": "unix2003",
        "HOME": "/Users/someone",
        "LOGNAME": "someone",
        "OSLogRateLimit": "64",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "SHELL": "/bin/zsh",
        "SSH_AUTH_SOCK": "/var/run/com.apple.launchd.x/Listeners",
        "TMPDIR": "/var/folders/x/T/",
        "USER": "someone",
        "XPC_FLAGS": "0x0",
        "XPC_SERVICE_NAME": "application.local.hammerdeck",
        "__CFBundleIdentifier": "local.hammerdeck",
        "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0",
    ]

    // Every fixture-based case below catches a SHRUNKEN keep-list and never a
    // grown one -- and growth is the direction that leaks. Both lists are
    // therefore pinned to the measurement itself.
    func testKeepListsArePinnedToTheMeasurement() {
        XCTAssertEqual(LaunchEnvironment.guiKeys, Set(guiEnv.keys))
        XCTAssertEqual(LaunchEnvironment.keptPrefixes, ["HAMMERDECK_", "XPC_", "__CF"])
        XCTAssertEqual(LaunchEnvironment.guiPath, "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    // A Dock launch must come out untouched.
    func testGuiLaunchIsUnchanged() {
        XCTAssertEqual(LaunchEnvironment.guiEnvironment(from: guiEnv), guiEnv)
    }

    // PATH is the case a name filter cannot fix: it is a GUI key, so it survives
    // the filter carrying the shell's homebrew/nvm value unless it is rewritten.
    func testShellVarsGoAndPathIsRewritten() {
        var env = guiEnv
        env["EXAMPLE_API_KEY"] = "not-a-real-key"
        env["NVM_DIR"] = "/Users/someone/.nvm"
        env["VSCODE_INJECTION"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/bin"

        let kept = LaunchEnvironment.guiEnvironment(from: env)
        XCTAssertEqual(Set(kept.keys), Set(guiEnv.keys))
        XCTAssertEqual(kept["PATH"], LaunchEnvironment.guiPath)
    }

    // The dev knobs are why a terminal launch happens at all; stripping them
    // would break `swift run` with a custom lua dir instead of just cleaning it.
    func testDevKnobsSurvive() {
        var env = guiEnv
        env["HAMMERDECK_LUA_DIR"] = "/repo/app"
        env["HAMMERDECK_CONTROL_DIR"] = "/tmp/control"
        let kept = LaunchEnvironment.guiEnvironment(from: env)
        XCTAssertEqual(kept["HAMMERDECK_LUA_DIR"], "/repo/app")
        XCTAssertEqual(kept["HAMMERDECK_CONTROL_DIR"], "/tmp/control")
    }
}
