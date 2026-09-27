import SwiftUI

// memory_room's gallery card (FeatureArchetype.memoryRoom): the default room with
// a few apps in their places, drawn as the room opens by default (no letters), and
// one place after another lighting as if picked -- "find it by where it lives".
// Its pins are animation FIXTURES, not the feature's real default record (that
// lives in room.lua): the card must look the same on every Mac, whatever the
// user has placed.
struct MemoryRoomArchetypeScene: View {
    let playing: Bool

    // nonisolated: read by the nonisolated FeatureArchetype.loopDuration.
    nonisolated static let heartbeat = 0.9
    nonisolated static let loopDuration = heartbeat * Double(fixtures.count)

    nonisolated private static let fixtures: [(key: String, x: Double, y: Double, app: String)] = [
        ("d", 0.29, 0.46, "com.apple.Safari"),
        ("k", 0.75, 0.56, "com.apple.Terminal"),
        ("w", 0.12, 0.22, "com.apple.Notes"),
        ("u", 0.62, 0.20, "com.apple.mail"),
    ]

    @State private var lit = 0

    var body: some View {
        let pins = Self.fixtures.enumerated().map { i, f in
            RoomPinDisplay(id: f.key, key: f.key, name: "", x: f.x, y: f.y, apps: [f.app])
        }
        let image = RoomImage.load(nil)
        RoomCanvas(image: image, pins: pins,
                   selected: playing ? Self.fixtures[lit].key : nil,
                   scale: 0.8, showKeys: false)
            .aspectRatio(RoomImage.aspect(image), contentMode: .fit)
            .animation(.easeInOut(duration: 0.25), value: lit)
            .heartbeat(Self.heartbeat, active: playing,
                       onStart: { lit = 0 },
                       onTick: { lit = (lit + 1) % Self.fixtures.count })
    }
}
