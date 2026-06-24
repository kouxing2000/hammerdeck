import SwiftUI

// The Swift half of the "features can contribute NATIVE pages" seam.
//
// A feature declares it has a page in its Lua manifest (`page = {title, icon}`),
// which describe() surfaces and the Homepage sidebar lists. The actual view is
// SwiftUI, so it cannot come from Lua -- it is registered HERE, keyed by feature
// id. The sidebar shows a page only when BOTH halves are present: the manifest
// declaration (title/icon, the single source of truth) and a view registered
// below. That keeps native UI "plug-in-like": adding a page is one Lua field +
// one Swift view + one line in this table -- never an edit to a central
// navigation enum or a detail switch.
//
// Page views receive only the SettingsStore: it carries the catalog (enable
// state, the page's own FeatureInfo) and the `readerCall` seam a page uses to
// pull its data from a feature reader module (e.g. usage_stats' report.lua), so
// a page works even when its feature is disabled.
@MainActor
struct FeaturePageRegistry {
    static let shared = FeaturePageRegistry()

    typealias Builder = (SettingsStore) -> AnyView

    private let builders: [String: Builder]

    private init() {
        builders = [
            // featureId : how to build its native page
            "usage_stats": { store in AnyView(UsageReportView(store: store)) },
        ]
    }

    func isRegistered(_ featureId: String) -> Bool { builders[featureId] != nil }

    /// The registered view for a feature id, or nil if none. The host filters to
    /// registered+declared pages before ever calling this (SettingsStore.featurePages),
    /// so a nil here means a stale selection, not a normal path.
    func view(for featureId: String, store: SettingsStore) -> AnyView? {
        builders[featureId]?(store)
    }
}
