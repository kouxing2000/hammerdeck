import XCTest
import Foundation
@testable import HammerdeckKit

// Memory Room's built-in rooms: RoomImage.builtins is the one list (tile order,
// asset file, name), and its pictures are data the compiler cannot see -- a
// renamed or missing file would only show up as a blank tile.
final class MemoryRoomImageTests: XCTestCase {

    func testEveryBuiltinRoomShipsItsPictureAtTheStudysSize() throws {
        XCTAssertEqual(Set(RoomImage.builtins.map(\.id)).count, RoomImage.builtins.count,
                       "a built-in room id is listed twice")
        XCTAssertEqual(RoomImage.builtins.first?.id, RoomImage.defaultId,
                       "the Study (the record's nil) leads the picker")
        XCTAssertFalse(RoomImage.builtins.contains { RoomImage.isPhoto($0.id) },
                       "a built-in id with the photo prefix would be read as a user's photo")
        let study = try XCTUnwrap(RoomImage.load(nil), "the Study's picture is missing")
        let size = RoomImage.pixelSize(study)
        for room in RoomImage.builtins {
            let url = RoomImage.builtinURL(room.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing \(url.path)")
            // The default places are fractions of the Study; a room drawn to a
            // different shape would put them off their furniture.
            let img = try XCTUnwrap(NSImage(contentsOf: url), "unreadable \(url.lastPathComponent)")
            XCTAssertEqual(RoomImage.pixelSize(img), size, "\(room.id) is not the Study's size")
        }
    }

    func testTheRecordsImageResolvesToTheRightPicture() {
        XCTAssertEqual(RoomImage.url(nil), RoomImage.builtinURL("study"))
        XCTAssertEqual(RoomImage.url("neon").lastPathComponent, "neon.jpg")
        // A room a later version dropped still draws a room, not a blank board.
        XCTAssertEqual(RoomImage.url("no-such-room"), RoomImage.builtinURL("study"))
        XCTAssertEqual(RoomImage.url("room-ab12.jpg"),
                       RoomImage.folder.appendingPathComponent("room-ab12.jpg"))
        // A photo that is gone stays gone: the page's "photo missing" warning and the
        // canvas's plain board both key off this nil.
        XCTAssertNil(RoomImage.load("room-\(UUID().uuidString).jpg"))
        XCTAssertFalse(RoomImage.isPhoto("room-a/../x.jpg"), "a name with a path in it is never a photo copy")
    }

    // The hover preview is drawn inside a room that never grows, so an icon at an
    // edge is where a placement bug would hide: the bubble cut off by the card, or
    // sitting on the very icon it belongs to.
    @MainActor
    func testTheHoverPreviewStaysInTheRoomAndOffItsIcon() {
        let room = CGSize(width: 528, height: 330)
        let reach: CGFloat = 22                                  // the icon and its label, from its centre
        for aspect in [CGFloat(1.6), 0.6, 3.0] {
            for fx in stride(from: 0.02, through: 0.98, by: 0.08) {
                for fy in stride(from: 0.02, through: 0.98, by: 0.08) {
                    let p = CGPoint(x: fx * room.width, y: fy * room.height)
                    let f = RoomCanvas.previewFrame(at: p, aspect: aspect, in: room, scale: 1)
                    let at = "icon (\(fx), \(fy)) aspect \(aspect)"
                    XCTAssertTrue(CGRect(origin: .zero, size: room).contains(f), "leaves the room: \(at) -> \(f)")
                    // By its longer side: a tall window's picture is narrow by nature.
                    XCTAssertGreaterThanOrEqual(max(f.width, f.height), room.height * 0.3,
                                                "too small to read: \(at) -> \(f)")
                    let icon = CGRect(x: p.x - 16, y: p.y - reach, width: 32, height: 2 * reach)
                    XCTAssertFalse(f.intersects(icon), "covers its own icon: \(at) -> \(f)")
                }
            }
        }
        let low = RoomCanvas.previewFrame(at: CGPoint(x: 264, y: 290), aspect: 1.6, in: room, scale: 1)
        XCTAssertLessThan(low.maxY, 290 - reach, "an icon low in the room gets its picture above it")
        let high = RoomCanvas.previewFrame(at: CGPoint(x: 264, y: 40), aspect: 1.6, in: room, scale: 1)
        XCTAssertGreaterThan(high.minY, 40 + reach, "an icon near the top gets its picture below it")
    }

    // A window dropped onto another's icon lands beside it: the drop is the user's
    // aim, so it should move as little as it takes, and away from the icon it hit.
    @MainActor
    func testADroppedWindowLandsBesideTheIconItHitNotOnIt() {
        let room = CGSize(width: 528, height: 330)
        let size = CGSize(width: 60, height: 44)
        let b = CGRect(x: 200, y: 140, width: 60, height: 44)          // window B, centred at (230, 162)
        let clearDrop = CGPoint(x: 400, y: 80)
        XCTAssertEqual(RoomCanvas.landing(for: clearDrop, size: size, others: [b], in: room), clearDrop,
                       "a drop that covers nobody stays exactly where it was let go")

        let onto = CGPoint(x: 245, y: 165)                              // right of B's centre
        let at = RoomCanvas.landing(for: onto, size: size, others: [b], in: room)
        let box = CGRect(x: at.x - size.width / 2, y: at.y - size.height / 2, width: size.width, height: size.height)
        XCTAssertFalse(box.intersects(b), "it no longer covers B: \(at)")
        XCTAssertGreaterThan(at.x, b.midX, "it slides off the side it was dropped on")
        XCTAssertLessThan(hypot(at.x - onto.x, at.y - onto.y), size.width + 8, "and moves no further than it must")
        XCTAssertTrue(CGRect(origin: .zero, size: room).contains(at), "inside the room")

        let wall = (0..<9).flatMap { j in (0..<9).map { i in
            CGRect(x: CGFloat(i) * 60, y: CGFloat(j) * 40, width: 60, height: 40) } }
        XCTAssertEqual(RoomCanvas.landing(for: onto, size: size, others: wall, in: room), onto,
                       "a room with no free point: the drop stays where it was let go")
    }

    /// The next open judges two spots by room.lua's R.FOOT -- closer than it on both
    /// axes and one is drawn aside -- so a drop has to land clear of that too, not
    /// just clear of the other icon's box.
    func testADropLandsAFootprintClearOfTheOthers() {
        let room = CGSize(width: 720, height: 450)
        let size = CGSize(width: 40, height: 44)
        let foot = CGSize(width: 0.16, height: 0.14)                   // R.FOOT
        let b = CGRect(x: 300, y: 200, width: 40, height: 44)          // window B, centred at (320, 222)
        let beside = CGPoint(x: 370, y: 222)                            // clear of B's box, inside its footprint
        let at = RoomCanvas.landing(for: beside, size: size, others: [b], foot: foot, in: room)
        let dx = abs(at.x - b.midX) / room.width, dy = abs(at.y - b.midY) / room.height
        XCTAssertTrue(dx >= foot.width || dy >= foot.height,
                      "it lands where the next open sees no overlap: \(at) (dx \(dx), dy \(dy))")
        XCTAssertLessThan(hypot(at.x - beside.x, at.y - beside.y), foot.width * room.width,
                          "and no further than the footprint asks")
        let far = CGPoint(x: 600, y: 100)
        XCTAssertEqual(RoomCanvas.landing(for: far, size: size, others: [b], foot: foot, in: room), far,
                       "a drop already a footprint away stays where it was let go")
    }

    /// A label past the room's edge is drawn slid in or flipped above its icon,
    /// off the part of the pin that takes clicks, so a drop is moved in first.
    func testADropNearTheEdgeLandsWhollyInsideTheRoom() {
        let room = CGSize(width: 720, height: 450)
        let size = CGSize(width: 104, height: 44)
        let whole = CGRect(origin: .zero, size: room)
        func box(_ c: CGPoint) -> CGRect { CGRect(x: c.x - 52, y: c.y - 22, width: 104, height: 44) }
        // Moved straight in, to a few points inside the edge: no further.
        let cases: [(CGPoint, CGPoint)] = [(CGPoint(x: 360, y: 448), CGPoint(x: 360, y: 424)),
                                           (CGPoint(x: 5, y: 200), CGPoint(x: 56, y: 200)),
                                           (CGPoint(x: 719, y: 2), CGPoint(x: 664, y: 26))]
        for (drop, want) in cases {
            let at = RoomCanvas.landing(for: drop, size: size, others: [], in: room)
            XCTAssertTrue(whole.contains(box(at)), "\(drop) lands wholly inside: \(at)")
            XCTAssertEqual(at.x, want.x, accuracy: 0.01, "\(drop)")
            XCTAssertEqual(at.y, want.y, accuracy: 0.01, "\(drop)")
        }
        let foot = CGSize(width: 0.16, height: 0.14)
        let b = CGRect(x: 308, y: 400, width: 104, height: 44)          // a window on the bottom edge
        let at = RoomCanvas.landing(for: CGPoint(x: 360, y: 448), size: size, others: [b], foot: foot, in: room)
        XCTAssertTrue(whole.contains(box(at)), "still inside when it has to go around a window: \(at)")
        XCTAssertTrue(abs(at.x - b.midX) >= foot.width * room.width || abs(at.y - b.midY) >= foot.height * room.height,
                      "and clear of that window's footprint: \(at)")
    }

    @MainActor
    func testThePanelReadsTheFootprintTheRoomSends() {
        XCTAssertEqual(RoomPanel.Spec(["pins": [Any](), "foot": ["w": 0.16, "h": 0.14]]).foot,
                       CGSize(width: 0.16, height: 0.14))
        XCTAssertEqual(RoomPanel.Spec([:]).foot, .zero, "none sent: a drop keeps only the boxes clear")
    }
}
