import SwiftUI

// usage_stats' native-page contribution. The feature owns the binding between
// its id and its view here, in its OWN swift/ folder -- the platform only lists
// `UsageReportPage.self` in FeaturePageRegistry.roster. The page itself is
// UsageReportView; this is just the FeaturePageProvider seam onto it.
enum UsageReportPage: FeaturePageProvider {
    static let featureId = "usage_stats"

    static func makeView(store: SettingsStore) -> AnyView {
        AnyView(UsageReportView(store: store))
    }
}
