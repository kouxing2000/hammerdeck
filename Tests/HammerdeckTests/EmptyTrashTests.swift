import XCTest
@testable import HammerdeckKit

// The Empty the Trash rule effect. Without Full Disk Access, macOS refuses to
// LIST ~/.Trash at all, so the effect must report a failure there instead of
// reading the refusal as an empty Trash. An unreadable directory stands in for
// that denial.
final class EmptyTrashTests: XCTestCase {

    private func makeDir(files: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmptyTrashTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<files {
            try Data("x".utf8).write(to: dir.appendingPathComponent("item\(i)"))
        }
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    func testRemovesEveryItemAndReturnsTheCount() throws {
        let dir = try makeDir(files: 2)
        XCTAssertEqual(Native.emptyDirectory(dir), 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testAnEmptyDirectoryIsACleanZero() throws {
        XCTAssertEqual(Native.emptyDirectory(try makeDir(files: 0)), 0)
    }

    func testAMissingDirectoryIsACleanZero() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmptyTrashTests-missing-\(UUID().uuidString)")
        XCTAssertEqual(Native.emptyDirectory(dir), 0)
    }

    func testAnUnreadableDirectoryIsAFailureNotAnEmptyTrash() throws {
        // root ignores permission bits, so the directory would stay readable
        try XCTSkipIf(geteuid() == 0, "permission bits do not bind root")
        let dir = try makeDir(files: 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        XCTAssertEqual(Native.emptyDirectory(dir), -1)
    }
}
