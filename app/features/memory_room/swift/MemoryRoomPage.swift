import SwiftUI

// memory_room's native-page contribution. The feature owns the binding between
// its id and its view here, in its OWN swift/ folder -- the platform only lists
// `MemoryRoomPage.self` in FeaturePageRegistry.roster. The page itself is
// MemoryRoomView; this is just the FeaturePageProvider seam onto it.
enum MemoryRoomPage: FeaturePageProvider {
    static let featureId = "memory_room"

    static func makeView(store: SettingsStore) -> AnyView {
        AnyView(MemoryRoomView(store: store))
    }
}
