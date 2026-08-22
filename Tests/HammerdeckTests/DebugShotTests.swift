#if DEBUG
import XCTest
import AppKit
@testable import HammerdeckKit

// The blank-render detector behind `@shot`'s `blank=<bool>` field.
//
// Why this is worth a test. `blank=true` is DOCUMENTED (in the
// hammerdeck-visual-check skill) as the "this capture failed" signal, with an
// explicit instruction not to bother opening the PNG. That makes a false
// positive strictly worse than no signal: it hands the reader a confident wrong
// answer and sends them after a broken screenshot pipeline while the content
// they wanted sits in the file. The failure is invisible from the inside too --
// the capture succeeded, so nothing else complains.
//
// The defect this pins is a BLIND PHASE. The old detector sampled an 11x11 grid
// at fixed 1/13 fractions of the bitmap, so its vertical pitch grew with the
// image; against content laid out on its own regular rhythm (stacked cards, text
// rows) the two lattices can resonate and every sample lands in a gutter. It
// misreported the real General settings pane at 934x2833 that way.
//
// So the invariant under test is not "this one layout works" -- tuning a fixture
// until it passes proves nothing about the next layout. It is that content
// covering a fixed share of the rows must be found NO MATTER WHERE IT SITS.
// A phase sweep is what says that, and it stays true of any future sampler.
@MainActor
final class DebugShotTests: XCTestCase {

    /// A bitmap of white with dark text-row-sized marks at the given y offsets --
    /// the shape of a settings form: mostly gutter, occasional content. The marks
    /// are row-sized rather than full-width bands on purpose; a band is crossed
    /// by any sampling scheme and would prove nothing.
    private func bitmap(width: Int, height: Int, markYs: [Int]) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.black.setFill()
        for y in markYs {
            NSRect(x: 60, y: y, width: 220, height: 14).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The core invariant: a detector may not have a blind phase. Content on a
    /// regular rhythm must be seen wherever that rhythm starts -- otherwise some
    /// real layout eventually lands in the blind spot, which is exactly what
    /// happened to the General pane.
    func testNoLayoutPhaseIsInvisible() {
        // The real geometry that misreported, at the real capture size.
        let (w, h, rowPitch) = (934, 2833, 260)
        for phase in stride(from: 0, to: rowPitch, by: 20) {
            let markYs = stride(from: 40 + phase, to: h - 60, by: rowPitch).map { $0 }
            let rep = bitmap(width: w, height: h, markYs: markYs)
            XCTAssertFalse(DebugShot.looksBlank(rep),
                           "content at phase \(phase) went undetected -- blind spot")
        }
    }

    func testGenuinelyEmptyBitmapIsReportedBlank() {
        // The signal has to keep working, or the fix is just a disabled check.
        let rep = bitmap(width: 934, height: 2833, markYs: [])
        XCTAssertTrue(DebugShot.looksBlank(rep),
                      "a uniform bitmap is the failure this flag exists for")
    }

    func testSparseShortContentIsDetected() {
        // The ordinary feature-detail capture: short, and only a few rows of
        // content. Guards against a fix that only helps tall images.
        let rep = bitmap(width: 934, height: 950, markYs: [100, 400, 700])
        XCTAssertFalse(DebugShot.looksBlank(rep))
    }
}
#endif
