import XCTest
import Foundation
@testable import HammerdeckKit

// The crash offer reads files macOS writes, next to hang, spin and user-fault
// reports that carry the same bundle id. Offering one of those as "Hammerdeck
// quit unexpectedly" would be a false alarm, and offering a crash twice nags --
// so selection is the part worth pinning. The summary goes into a report the
// user may paste into a public issue, so path redaction is pinned too.
@MainActor
final class CrashReportsTests: XCTestCase {

    private var dir: URL!
    private let ours = "com.peach-studio.hammerdeck"

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func ips(bundleID: String, bugType: String = "309", stamp: String,
                     body: String = "{}") -> String {
        """
        {"app_name":"Hammerdeck","timestamp":"\(stamp)","app_version":"0.2.0","build_version":"42","bug_type":"\(bugType)","os_version":"macOS 26.5.2 (25F84)","bundleID":"\(bundleID)","name":"Hammerdeck"}
        \(body)
        """
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func date(_ s: String) -> Date { CrashReports.header(ips(bundleID: ours, stamp: s))!.date }

    func testHeaderParsesLocalTimestampWithOffset() {
        let h = CrashReports.header(ips(bundleID: ours, stamp: "2026-09-20 13:28:34.00 -0700"))
        XCTAssertEqual(h?.bundleID, ours)
        XCTAssertEqual(h?.bugType, "309")
        XCTAssertEqual(h?.date, ISO8601DateFormatter().date(from: "2026-09-20T20:28:34Z"))
    }

    func testPendingPicksNewestCrashOfOursOnly() throws {
        try write("Hammerdeck-2026-09-20-100000.ips", ips(bundleID: ours, stamp: "2026-09-20 10:00:00.00 -0700"))
        try write("Hammerdeck-2026-09-20-120000.ips", ips(bundleID: ours, stamp: "2026-09-20 12:00:00.00 -0700"))
        // Newer, but each disqualified for a different reason.
        try write("Hammerdeck-2026-09-20-130000.ips",
                  ips(bundleID: ours, bugType: "211", stamp: "2026-09-20 13:00:00.00 -0700"))   // not a crash
        try write("ExcUserFault_Hammerdeck-2026-09-20-140000.ips",
                  ips(bundleID: ours, stamp: "2026-09-20 14:00:00.00 -0700"))                  // wrong file family
        try write("Hammerdeck-2026-09-20-150000.ips",
                  ips(bundleID: "org.example.other", stamp: "2026-09-20 15:00:00.00 -0700"))  // another app
        try write("Hammerdeck-2026-09-20-160000.ips", "not json")

        let found = CrashReports.pending(in: dir, processName: "Hammerdeck", bundleID: ours,
                                         since: .distantPast)
        XCTAssertEqual(found?.url.lastPathComponent, "Hammerdeck-2026-09-20-120000.ips")
    }

    func testPendingIgnoresCrashesAtOrBeforeTheWatermark() throws {
        try write("Hammerdeck-a.ips", ips(bundleID: ours, stamp: "2026-09-20 12:00:00.00 -0700"))
        let seen = date("2026-09-20 12:00:00.00 -0700")
        XCTAssertNil(CrashReports.pending(in: dir, processName: "Hammerdeck", bundleID: ours, since: seen))
        XCTAssertNotNil(CrashReports.pending(in: dir, processName: "Hammerdeck", bundleID: ours,
                                             since: seen.addingTimeInterval(-1)))
    }

    func testSummaryCarriesTheCrashAndNoPaths() throws {
        let home = NSHomeDirectory()
        let body = """
        {"procName":"Hammerdeck","procPath":"\(home)/Downloads/Hammerdeck.app/Contents/MacOS/Hammerdeck",
         "exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
         "termination":{"indicator":"Trace/BPT trap: 5"},
         "asi":{"libswiftCore.dylib":["HammerdeckKit/LuaState.swift:109: Fatal error: bad state in \(home)/x"]},
         "faultingThread":0,
         "threads":[{"frames":[{"imageIndex":0,"imageOffset":1234,"symbol":"LuaState.call"},
                               {"imageIndex":1,"imageOffset":99,"symbol":"CFRunLoopRun"}]}],
         "usedImages":[{"name":"Hammerdeck","uuid":"AAAA-BBBB","path":"\(home)/Downloads/Hammerdeck.app/Contents/MacOS/Hammerdeck"},
                       {"name":"CoreFoundation","path":"/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"}]}
        """.replacingOccurrences(of: "\n", with: "")
        let text = try XCTUnwrap(CrashReports.summary(ips(bundleID: ours, stamp: "2026-09-20 12:00:00.00 -0700",
                                                         body: body)))
        XCTAssertTrue(text.contains("exception: EXC_BREAKPOINT (SIGTRAP)"), text)
        XCTAssertTrue(text.contains("Fatal error: bad state"), text)
        XCTAssertTrue(text.contains("image: Hammerdeck AAAA-BBBB"), text)
        XCTAssertTrue(text.contains("Hammerdeck  LuaState.call  +1234"), text)
        XCTAssertTrue(text.contains("CoreFoundation  CFRunLoopRun  +99"), text)
        XCTAssertFalse(text.contains(home), "the account short name must not survive: \(text)")
        XCTAssertFalse(text.contains("/System/Library"), "image paths must not be emitted: \(text)")
        XCTAssertFalse(text.contains("Downloads"), "procPath must not be emitted: \(text)")
    }

    func testIssueURLFitsAndSaysWhereTheRestIs() throws {
        let long = String(repeating: "line: with punctuation ~/:?\n", count: 2000)
        let url = try XCTUnwrap(StatusBarController.issueURL(title: "Hammerdeck 0.2.0 -- ", body: long))
        XCTAssertLessThanOrEqual(url.absoluteString.count, 7500)
        XCTAssertTrue(url.absoluteString.contains("clipboard"), "a cut body must point at the full copy")

        let short = try XCTUnwrap(StatusBarController.issueURL(title: "t", body: "all of it"))
        XCTAssertTrue(short.absoluteString.contains("all%20of%20it"), short.absoluteString)
        XCTAssertFalse(short.absoluteString.contains("clipboard"))
    }

    func testIssueURLTerminatesWhenTheTitleAloneIsTooLong() {
        let title = String(repeating: "x", count: 9000)
        XCTAssertNotNil(StatusBarController.issueURL(title: title, body: "body"))
    }
}
