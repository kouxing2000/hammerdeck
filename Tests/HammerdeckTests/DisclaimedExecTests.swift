import Darwin
import XCTest
@testable import HammerdeckKit

/// `run_process` (the runCommand rule effect and an extension's `ctx.run`) must start
/// its command WITHOUT Hammerdeck's privacy grants: through the DisclaimedExec
/// trampoline, so the command is its own responsible process. Asserted at the wiring
/// altitude -- through `adapter.run` on the real bridge -- because the defect this
/// guards is a launch path that forgets the trampoline, not the trampoline itself.
///
/// Responsibility is read with the same private SPI family the trampoline uses,
/// while the child is still alive (it writes its pid, then sleeps), and checked
/// against a CONTROL child launched without the trampoline, whose responsible
/// process is the test runner's -- so the assertion can fail in both directions.
/// Full Disk Access reads are deliberately not asserted: whether one succeeds
/// depends on what granted the process that launched the tests.
@MainActor
final class DisclaimedExecTests: XCTestCase {

    private typealias ResponsibleFor = @convention(c) (pid_t) -> pid_t
    private let responsibleFor: ResponsibleFor? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let sym = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFor.self)
    }()

    private func tempFile(_ tag: String) -> String {
        NSTemporaryDirectory() + "hd-disclaim-\(tag)-\(UUID().uuidString)"
    }

    /// Spin the main run loop until `file` holds a pid (the child is up), or time out.
    private func pid(from file: String, timeout: TimeInterval = 10) -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = try? String(contentsOfFile: file, encoding: .utf8),
               let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return p
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    /// Run `script` through `adapter.run` (the real `run_process` binding) and wait
    /// for its callback; returns the status it reported.
    private func runThroughAdapter(_ script: String, timeout: TimeInterval = 20) throws -> Int? {
        try TestHost.shared.lua.run("""
            _G.__discStatus = nil
            require("platform.adapter").run("/bin/sh", { "-c", \(luaQuote(script)) },
                function(status) _G.__discStatus = status or "nil" end)
            """)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let v = try TestHost.shared.lua.eval("return _G.__discStatus") {
                return (v as? Double).map { Int($0) }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("adapter.run never called back for: \(script)")
        return nil
    }

    private func luaQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func testTheTrampolineBinaryIsThere() {
        _ = TestHost.shared   // boot the bridge (sets the trampoline override)
        let path = Native.trampolineOverride ?? ""
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path),
                      "the test host points run_process at \(path), which is not an executable "
                      + "-- `swift test` must build the Hammerdeck product beside the test bundle")
    }

    func testARunProcessChildIsItsOwnResponsibleProcess() throws {
        let responsibleFor = try XCTUnwrap(responsibleFor, "the responsibility SPI is missing")
        _ = TestHost.shared   // boot the bridge (sets the trampoline override)

        // The command under test, through the real binding.
        let file = tempFile("adapter")
        try TestHost.shared.lua.run("""
            require("platform.adapter").run("/bin/sh", { "-c", \(luaQuote("echo $$ > '\(file)'; sleep 5")) },
                function() end)
            """)
        let child = try XCTUnwrap(pid(from: file), "the run_process child never started")
        let childResponsible = responsibleFor(child)
        kill(child, SIGTERM)

        // The control: the same script launched WITHOUT the trampoline.
        let controlFile = tempFile("control")
        _ = Native.shared.runProcessCore(executable: "/bin/sh",
                                         args: ["-c", "echo $$ > '\(controlFile)'; sleep 5"],
                                         timeout: 10, label: "test") { _, _, _ in }
        let control = try XCTUnwrap(pid(from: controlFile), "the control child never started")
        let controlResponsible = responsibleFor(control)
        kill(control, SIGTERM)

        XCTAssertNotEqual(controlResponsible, control,
                          "control: a plainly launched child is attributed to its launcher -- "
                          + "if this fails, the probe below proves nothing")
        XCTAssertEqual(childResponsible, child,
                       "a run_process child must be its own responsible process, so it inherits "
                       + "none of Hammerdeck's privacy grants")
        try? FileManager.default.removeItem(atPath: file)
        try? FileManager.default.removeItem(atPath: controlFile)
    }

    func testExitCodeAndSignalDeathPassThroughTheTrampoline() throws {
        _ = TestHost.shared
        XCTAssertEqual(try runThroughAdapter("exit 3"), 3, "the command's own exit code reaches the caller")
        XCTAssertEqual(try runThroughAdapter("kill -TERM $$"), -15,
                       "a signal death still reads as one (negative), not as an exit code")
    }

    /// The documented contract: nil when the program could not be launched at all.
    /// The trampoline is what fails to start it now, and it exits 127 -- which must
    /// not reach the caller as an exit code the command chose.
    func testAProgramThatCannotStartReportsNilNotAnExitCode() throws {
        _ = TestHost.shared
        try TestHost.shared.lua.run("""
            _G.__discMissing = nil
            require("platform.adapter").run("/nonexistent/hd-no-such-program", {},
                function(status, _, stderr)
                    _G.__discMissing = (status == nil and "nil" or tostring(status)) .. "|" .. stderr
                end)
            """)
        let deadline = Date().addingTimeInterval(20)
        var got: String?
        while got == nil, Date() < deadline {
            got = try TestHost.shared.lua.eval("return _G.__discMissing") as? String
            if got == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        let r = try XCTUnwrap(got, "adapter.run never called back for a missing program")
        XCTAssertTrue(r.hasPrefix("nil|"), "status must be nil, not the trampoline's 127 -- got: \(r)")
        XCTAssertTrue(r.contains("could not start"), "stderr still carries the reason: \(r)")
    }

    func testRunProcessRefusesWhenTheTrampolineIsMissing() throws {
        _ = TestHost.shared
        let saved = Native.trampolineOverride
        Native.trampolineOverride = "/nonexistent/Hammerdeck"
        defer { Native.trampolineOverride = saved }
        let err = try TestHost.shared.lua.eval("""
            local ok, e = pcall(function()
                return require("platform.adapter").run("/bin/echo", { "hi" }, function() end)
            end)
            return (not ok) and tostring(e) or "NO ERROR RAISED"
            """) as? String ?? ""
        XCTAssertTrue(err.contains("could not be found"),
                      "with no trampoline the command is refused, never run with inherited "
                      + "permissions -- got: \(err)")
    }

    func testTheTrampolineRefusesToRunNothing() {
        _ = TestHost.shared
        let trampoline = Native.trampolineOverride ?? ""
        let done = expectation(description: "trampoline exits")
        let box = ExitBox()
        _ = Native.shared.runProcessCore(executable: trampoline, args: [DisclaimedExec.flag],
                                         timeout: 10, label: "test") { s, _, e in
            box.set(s, String(decoding: e, as: UTF8.self))
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        let r = box.get()
        XCTAssertEqual(r.status, 127)
        XCTAssertTrue(r.err.contains("no command given"), "stderr says why: \(r.err)")
    }
}

/// runProcessCore's completion runs off the main actor; hand its values back locked.
private final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: (status: Int32?, err: String) = (nil, "")
    func set(_ s: Int32?, _ e: String) { lock.lock(); v = (s, e); lock.unlock() }
    func get() -> (status: Int32?, err: String) { lock.lock(); defer { lock.unlock() }; return v }
}
