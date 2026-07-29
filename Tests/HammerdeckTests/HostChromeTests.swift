import XCTest
@testable import HammerdeckKit

// Conventions of the host WINDOW CHROME that only a source scan can hold -- the
// rules that are invisible at the type level and that no runtime assertion sees,
// because breaking them still compiles, still runs, and only shows up as a wrong
// window title in a screenshot someone happens to look at.
final class HostChromeTests: XCTestCase {

    // The window title is declared EXACTLY ONCE, at the NavigationSplitView shell
    // (HomepageView), and never on a detail page.
    //
    // Why this is a gate and not a comment. Inside the NSHostingController-hosted
    // NavigationSplitView, a DETAIL's .navigationTitle silently becomes the
    // NSWindow's title -- and then persists after navigating away. That shipped:
    // opening a feature page retitled the whole window to that feature, so Home
    // sat under "Bing Daily Wallpaper" until the app relaunched. Removing the
    // three offending calls fixed it, but nothing stopped the next page from
    // adding one back -- and a detail's title WINS over the shell's, so pinning
    // the real title at the shell does not defend itself. This scan is what makes
    // "declared once, at the shell" a guarantee instead of a hope.
    //
    // If a page genuinely needs its own title, it belongs in the page's content
    // (a heading view), not in the window chrome -- see FeatureDetail's heading.
    func testWindowTitleIsDeclaredOnlyAtTheShell() throws {
        let root = repoRoot()
        let uiRoot = root + "/app"
        var sites: [String] = []

        let enumerator = FileManager.default.enumerator(atPath: uiRoot)
        var scanned = 0
        while let rel = enumerator?.nextObject() as? String {
            guard rel.hasSuffix(".swift"),
                  let src = try? String(contentsOfFile: uiRoot + "/" + rel, encoding: .utf8)
            else { continue }
            scanned += 1
            for (i, line) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // Skip commented-out mentions: the removal sites carry explanatory
                // comments that NAME this modifier, and a gate that counted those
                // would fire on its own documentation.
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), code.contains(".navigationTitle(") else { continue }
                sites.append("\(rel):\(i + 1)")
            }
        }

        // Assert the FILE, never a line number -- a pinned line drifts on the
        // next edit above it and the gate starts failing on innocent changes.
        let files = sites.map { String($0.split(separator: ":")[0]) }

        // A scan that reads no sources would pass while checking nothing.
        XCTAssertGreaterThan(scanned, 0, "scanned no Swift sources under \(uiRoot)")
        XCTAssertEqual(files, ["platform/swift/HomepageView.swift"],
                       "the window title must be declared exactly once, at the "
                       + "NavigationSplitView shell in HomepageView. A detail page's "
                       + ".navigationTitle becomes the WINDOW title and sticks there "
                       + "after navigation -- put the page's title in its content "
                       + "instead. Found:\n  " + sites.joined(separator: "\n  "))
    }

    // `mode` sanitizes what it reads out of the defaults domain. That is the half
    // worth a gate, and it is NOT covered by the mode -> NSAppearance mapping:
    // `mode` also feeds the Settings picker's `selection`, so an unrecognized raw
    // value yields a tag no segment carries and the control renders with NOTHING
    // selected. The value is a raw string on disk, so a hand-edited `defaults
    // write`, a downgrade, or a renamed mode can all deliver one -- and the
    // earlier shape of this bug in this codebase (set_appearance's unknown-mode
    // note) was to silently pick a branch, wrong half the time.
    func testAppearancePreferenceSanitizesWhatItReadsFromDefaults() {
        let key = AppearancePreference.key
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(AppearancePreference.mode, AppearancePreference.system,
                       "an unset key must follow macOS")
        UserDefaults.standard.set("dark", forKey: key)
        XCTAssertEqual(AppearancePreference.mode, "dark", "a known mode survives the round trip")
        UserDefaults.standard.set("sepia", forKey: key)
        XCTAssertEqual(AppearancePreference.mode, AppearancePreference.system,
                       "an unrecognized mode must fall back, not reach the picker as a dead tag")
        UserDefaults.standard.set(42, forKey: key)
        XCTAssertEqual(AppearancePreference.mode, AppearancePreference.system,
                       "a non-string value must fall back too")
    }

    private func repoRoot(file: StaticString = #filePath) -> String {
        URL(fileURLWithPath: "\(file)")            // .../Tests/HammerdeckTests/HostChromeTests.swift
            .deletingLastPathComponent()           // .../Tests/HammerdeckTests
            .deletingLastPathComponent()           // .../Tests
            .deletingLastPathComponent()           // repo root
            .path
    }
}
