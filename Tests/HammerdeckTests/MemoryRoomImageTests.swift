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
}
