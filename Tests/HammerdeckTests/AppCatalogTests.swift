import XCTest
import AppKit
@testable import HammerdeckKit

// Host-UI app catalog: the bundle-id -> name resolution behind the rules editor's
// app-target picker (the rules list renders a stored bundle id readably through it).
// The matching LOGIC -- a rule dispatching by bundle id, falling back to name -- is
// covered in Lua (test/run.lua T39b4). The Spotlight installedApps() enumerator is
// verified visually (does the picker populate): a unit test would either flake on a
// CI runner without Spotlight or risk hanging on a query that never fires.
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
}
