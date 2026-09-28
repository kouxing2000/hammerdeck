import SwiftUI

// memory_room's gallery card (FeatureArchetype.memoryRoom): the default room with
// four windows of ONE app, each at its spot with a short label, drawn as the room
// opens, and one after another lighting as if picked --
// "find it by where it lives". Its windows are animation FIXTURES, not anything
// the room has seen: the card must look the same on every Mac. Terminal, because
// every Mac has it.
struct MemoryRoomArchetypeScene: View {
    let playing: Bool

    // nonisolated: read by the nonisolated FeatureArchetype.loopDuration.
    nonisolated static let heartbeat = 0.9
    nonisolated static let loopDuration = heartbeat * Double(fixtures.count)

    nonisolated private static let fixtures: [(label: String, x: Double, y: Double)] = [
        ("api", 0.29, 0.46),
        ("web", 0.75, 0.56),
        ("docs", 0.12, 0.22),
        ("infra", 0.48, 0.80),
    ]

    @State private var lit = 0

    var body: some View {
        let pins = Self.fixtures.map { f in
            RoomPinDisplay(id: f.label, name: f.label, title: f.label, x: f.x, y: f.y,
                           apps: ["com.apple.Terminal"])
        }
        let image = RoomImage.load(nil)
        RoomCanvas(image: image, pins: pins,
                   selected: playing ? Self.fixtures[lit].label : nil,
                   scale: 0.8)
            .aspectRatio(RoomImage.aspect(image), contentMode: .fit)
            .animation(.easeInOut(duration: 0.25), value: lit)
            .heartbeat(Self.heartbeat, active: playing,
                       onStart: { lit = 0 },
                       onTick: { lit = (lit + 1) % Self.fixtures.count })
    }
}
