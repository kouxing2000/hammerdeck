import SwiftUI

// The Swift half of the "features can contribute NATIVE pages" seam.
//
// A feature declares it has a page in its feature.json (`page = {title, icon}`),
// which describe() surfaces and the Homepage sidebar lists. The actual view is
// SwiftUI, so it cannot come from Lua -- it is contributed HERE by the feature's
// own Swift, through the FeaturePageProvider interface below. The sidebar shows a
// page only when BOTH halves are present: the feature.json declaration
// (title/icon, the single source of truth) and a provider for that id.
//
// WHY a provider interface instead of a central builder dict: a feature OWNS the
// binding between its id and its view. The platform must not know how to build a
// feature's view -- it only knows the LIST of providers (the `roster` below).
// Adding a page is: one feature.json field + one Swift view + one
// FeaturePageProvider in the feature's OWN swift/ folder + one `.self` line in
// the roster. That last line is the unavoidable static-Swift floor: SwiftPM
// compiles one target and dead-strips unreferenced types, so a provider must be
// named somewhere reachable. It parallels the per-feature line this same dir
// already requires in Package.swift's `sources`.
//
// A provider receives only the SettingsStore: it carries the catalog (enable
// state, the page's own FeatureInfo) and the `readerCall` seam a page uses to
// pull its data from a feature reader module (e.g. usage_stats' report.lua), so
// a page works even when its feature is disabled.

/// The extension point a feature implements to contribute a native Homepage
/// page. Live next to the feature's view, in its own `swift/` folder -- the
/// feature owns the id<->view binding, not the platform.
@MainActor
protocol FeaturePageProvider {
    /// The feature id this page belongs to (the feature's feature.json id, which
    /// the Lua manifest id anchors -- they must match).
    static var featureId: String { get }
    /// Build the page's SwiftUI view. Type-erased because the roster is heterogeneous.
    static func makeView(store: SettingsStore) -> AnyView
}

@MainActor
struct FeaturePageRegistry {
    static let shared = FeaturePageRegistry()

    /// The one central touch-point: every feature that contributes a native page
    /// names its provider here. Keep it a bare list -- no view-building logic, no
    /// id strings; those live in each provider, in the feature's own folder.
    private static let roster: [FeaturePageProvider.Type] = [
        UsageReportPage.self,
    ]

    private let builders: [String: (SettingsStore) -> AnyView]

    private init() {
        // reduce (not Dictionary(uniqueKeysWithValues:)) so a duplicate id names
        // the offending feature instead of an opaque trap. A clash is programmer
        // error in the static roster -- caught in debug, last-wins in release.
        builders = Self.roster.reduce(into: [:]) { dict, provider in
            assert(dict[provider.featureId] == nil,
                   "duplicate FeaturePageProvider for featureId \"\(provider.featureId)\"")
            dict[provider.featureId] = provider.makeView
        }
    }

    func isRegistered(_ featureId: String) -> Bool { builders[featureId] != nil }

    /// The contributed view for a feature id, or nil if none. The host filters to
    /// registered+declared pages before ever calling this (SettingsStore.featurePages),
    /// so a nil here means a stale selection, not a normal path.
    func view(for featureId: String, store: SettingsStore) -> AnyView? {
        builders[featureId]?(store)
    }
}
