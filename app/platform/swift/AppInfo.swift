import Foundation

// The single source of truth for the user-visible app DISPLAY name.
//
// The OS-level name is already single-sourced: scripts/package.sh writes
// CFBundleName/CFBundleDisplayName from its APP_NAME var into the packaged
// Info.plist. So the in-app display strings just read that plist key at runtime,
// guaranteeing they agree with what Finder/Dock/the menubar show.
//
// In a dev `swift run` there is no .app / Info.plist, so the read returns nil
// and we fall back to the literal -- the only place the brand string lives in
// Swift source. Internal identifiers (target/module names, the bundle id, the
// `hammerdeck.*` UserDefaults keys, `.../Hammerdeck/...` filesystem paths) are
// NOT display strings and must never be sourced from here.
//
// The brand is deliberately NOT localized: callers inject `displayName` into
// localized templates as an argument (e.g. "%@ needs Accessibility"), never as a
// translated key.
enum AppInfo {
    static let displayName: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? "Hammerdeck"
}
