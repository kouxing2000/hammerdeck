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

    // A THEMED layer color must actually re-resolve when the theme flips. This is
    // the mechanism behind TintedView, and it has two halves that both broke once:
    //
    //   1. The alpha must be applied LATE. `labelColor.withAlphaComponent(0.10)`
    //      is a static color -- frozen at construction -- so passing one in would
    //      pin whatever theme was current then. TintedView takes the alpha as a
    //      separate field for exactly this reason.
    //   2. Resolution must fold VIBRANCY. A subview of a `.menu` effect view has a
    //      vibrant appearance, where `.separatorColor` is an OPAQUE gray rather
    //      than a faint white/black -- which silently restyled a divider from a
    //      light hairline into a dark rule the first time these views were used.
    //
    // Asserting on the resolved LAYER colors (not on the NSColors) is what makes
    // this catch either regression: both failures are invisible at the type level
    // and produce a perfectly valid CGColor.
    @MainActor
    func testThemedLayerColorsReResolveAcrossAThemeFlip() throws {
        // A .menu vibrancy host, so the vibrant-folding half is under test too.
        let host = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        host.material = .menu
        host.state = .active
        host.wantsLayer = true

        let ink = TintedView(frame: NSRect(x: 0, y: 0, width: 100, height: 1))
        ink.fill = .labelColor
        ink.fillAlpha = 0.10
        let separator = TintedView(frame: NSRect(x: 0, y: 2, width: 100, height: 1))
        separator.fill = .separatorColor
        host.addSubview(ink)
        host.addSubview(separator)

        func paint(_ appearance: NSAppearance.Name) -> [CGColor] {
            host.appearance = NSAppearance(named: appearance)
            for v in [ink, separator] { v.needsDisplay = true; v.displayIfNeeded() }
            return [ink, separator].map { $0.layer?.backgroundColor ?? .clear }
        }
        let light = paint(.aqua), dark = paint(.darkAqua)

        // Each color must actually DIFFER between themes -- a frozen color would
        // return byte-identical CGColors here, which is the whole failure mode.
        for (i, name) in ["labelColor+alpha", "separatorColor"].enumerated() {
            XCTAssertFalse(light[i] == dark[i],
                           "\(name) resolved identically in light and dark (\(light[i])) -- "
                           + "it is frozen, not themed")
        }
        // ... and in the right DIRECTION: ink over the card is dark-on-light and
        // light-on-dark. A vibrant opaque gray would fail the alpha check, which is
        // what pins the vibrancy folding.
        for (i, name) in ["labelColor+alpha", "separatorColor"].enumerated() {
            let l = try XCTUnwrap(light[i].components), d = try XCTUnwrap(dark[i].components)
            XCTAssertEqual(l[0], 0, accuracy: 0.01, "\(name) light form should be black ink")
            XCTAssertEqual(d[0], 1, accuracy: 0.01, "\(name) dark form should be white ink")
            XCTAssertLessThan(try XCTUnwrap(l.last), 0.5,
                              "\(name) light form should be faint, not opaque (vibrant leak?)")
            XCTAssertLessThan(try XCTUnwrap(d.last), 0.5,
                              "\(name) dark form should be faint, not opaque (vibrant leak?)")
        }
    }

    // The call-site half of the same bug class, as a source scan, because the class
    // is open-ended -- any future panel can reintroduce it, and CLAUDE.md prefers a
    // lint for a whole bug class over per-instance assertions. It is exactly what
    // would have caught the chooser's accent band shipping half-fixed:
    // `headerBackground.fill = NSColor.controlAccentColor.withAlphaComponent(0.18)`
    // type-checks, looks themed, and is frozen.
    //
    // Deliberately scoped to `TintedView`'s own `fill`/`stroke` and NOT to raw
    // `layer?.backgroundColor` writes. Baking an alpha into a TintedView defeats
    // the one thing the class exists for, so it is unambiguous. Baking one into a
    // plain view is a LIFETIME question a source scan cannot answer: it is a real
    // bug for a view that outlives a theme change and perfectly correct for one
    // rebuilt on every show, which is what WindowPickerPanel / DisplayPickerPanel
    // do. Flagging those would demand an allowlist saying "this one is fine",
    // which is how a gate turns into noise nobody reads.
    func testNoFrozenAlphaAssignedToAThemedLayerColor() throws {
        let root = repoRoot()
        // Only a DYNAMIC receiver is a defect. `NSColor.white.withAlphaComponent(_:)`
        // is static by design and correct -- the always-dark HUD overlays are built
        // on exactly that. So capture the color the alpha is applied TO and judge
        // it, rather than flagging the call. The allowlist is the small, stable set
        // of device-constant colors; every semantic name (labelColor, separator,
        // controlAccent, system*) is dynamic and therefore caught BY DEFAULT, so a
        // new one Apple adds needs no edit here.
        let staticBasics: Set<String> = [
            "white", "black", "clear", "gray", "darkGray", "lightGray",
            "red", "green", "blue", "cyan", "magenta", "yellow", "orange",
            "purple", "brown",
        ]
        let pattern = try NSRegularExpression(
            pattern: #"\.(?:fill|stroke)\s*=\s*"#
                   + #"[^\n]*?(?:NSColor)?\.([A-Za-z][A-Za-z0-9]*)\s*\.withAlphaComponent"#)
        var offenders: [String] = [], scanned = 0

        let enumerator = FileManager.default.enumerator(atPath: root + "/app")
        while let rel = enumerator?.nextObject() as? String {
            guard rel.hasSuffix(".swift"),
                  let src = try? String(contentsOfFile: root + "/app/" + rel, encoding: .utf8)
            else { continue }
            scanned += 1
            let ns = src as NSString
            for m in pattern.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
                let receiver = ns.substring(with: m.range(at: 1))
                guard !staticBasics.contains(receiver) else { continue }
                let line = ns.substring(with: ns.lineRange(for: m.range))
                offenders.append("\(rel) [\(receiver)]: "
                                 + line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        XCTAssertGreaterThan(scanned, 0, "scanned no Swift sources under \(root)/app")
        XCTAssertTrue(offenders.isEmpty,
                      "\(offenders.count) themed layer color(s) bake their alpha at the call "
                      + "site. `someSemanticColor.withAlphaComponent(x)` is a STATIC color -- it "
                      + "freezes whatever theme was current when it was built. Pass the whole "
                      + "color and set TintedView's fillAlpha/strokeAlpha instead, or use "
                      + "NSColor.dynamic for a design color with no semantic equivalent:\n  "
                      + offenders.joined(separator: "\n  "))
    }

    private func repoRoot(file: StaticString = #filePath) -> String {
        URL(fileURLWithPath: "\(file)")            // .../Tests/HammerdeckTests/HostChromeTests.swift
            .deletingLastPathComponent()           // .../Tests/HammerdeckTests
            .deletingLastPathComponent()           // .../Tests
            .deletingLastPathComponent()           // repo root
            .path
    }
}
