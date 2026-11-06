import XCTest
import AppKit
@testable import HammerdeckKit

// Host-UI app catalog: the bundle-id -> name resolution behind the rules editor's
// app-target picker (the rules list renders a stored bundle id readably through it).
// The matching LOGIC -- a rule dispatching by bundle id, falling back to name -- is
// covered in Lua (test/run.lua T39b4). Installed-app coverage exercises the real
// directory scan through both the host picker and the launcher's Lua seam.
@MainActor
final class AppCatalogTests: XCTestCase {

    // Launch Services resolves a ubiquitous system app's bundle id to a display name
    // (Finder is always installed) -- and an unknown id resolves to nil, not a crash.
    func testDisplayNameResolvesSystemApp() {
        XCTAssertNotNil(AppCatalog.displayName(forBundleId: "com.apple.finder"),
                        "Finder's bundle id should resolve to a display name")
        XCTAssertNil(AppCatalog.displayName(forBundleId: "com.example.no.such.app.zzz"),
                     "an unknown bundle id resolves to nil")
    }

    func testInstalledAppPickerIncludesFinder() {
        let finders = AppCatalog.installedApps().filter { $0.bundleId == "com.apple.finder" }
        XCTAssertEqual(finders.count, 1, "Finder must be selectable even outside the Applications folders")
        XCTAssertFalse(finders.first?.name.isEmpty ?? true)
    }

    func testLauncherCatalogIncludesFinder() throws {
        let apps = try XCTUnwrap(try TestHost.shared.lua.eval("""
            return require('platform.adapter').installedApps()
            """) as? [[String: Any]])
        let finders = apps.filter { $0["bundleId"] as? String == "com.apple.finder" }
        XCTAssertEqual(finders.count, 1, "The launcher must receive Finder from the native scan")
        XCTAssertEqual(finders.first?["path"] as? String,
                       "/System/Library/CoreServices/Finder.app")
    }
}
