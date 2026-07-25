import Foundation

// One row per effect kind: its verb, how it SERIALIZES out of the form, and how
// it LOADS back in. The Swift twin of effects.lua's EFFECT_KINDS table, which has
// been table-driven all along -- this file is what finally makes the two halves
// symmetric.
//
// WHY (CODE-4): adding one effect kind used to mean editing roughly eight
// places, five of which were parallel `switch`/if-chains over the same string.
// Nothing tied them together, so the failure mode was partial: a kind that
// serialized correctly but had no verb (blank pill), or loaded but would not
// validate. Every one of those is silent -- the build stays green and the rule
// editor just quietly misbehaves for that kind.
//
// A kind now needs a row here plus its token pill in RulesView (the pill builds
// SwiftUI views bound to live @State, so it is genuinely a view switch, not data
// -- forcing it into this table would buy nothing). Two sites, not eight, and a
// missing row is caught by a test rather than by a user.
//
// `build` doubles as the completeness check: it returns nil exactly when the form
// is too incomplete to serialize, which is the same question `canSubmit` asks.
// Keeping one definition means the Submit button can never disagree with what
// buildSpec would actually produce -- they used to be separate switches, and
// launchApp already differed between them (one required the bundle id, the other
// required id AND name).

// @MainActor, not @unchecked Sendable: the table is only ever read while
// building or submitting the rule form, which is main-actor UI work. Claiming
// Sendable would be a lie about the `[String: Any]` payloads flowing through
// these closures, and the honest annotation costs nothing here.
@MainActor
struct EffectKindSpec {
    let kind: String
    /// The sentence verb: catalog suffix under "rules.verb." + inline English.
    /// Stored as a SUFFIX so the call site can spell the prefix as a literal --
    /// the localization gate resolves dynamic keys by literal prefix, and a bare
    /// `Strings.t(someVariable)` is a site it cannot vouch for (see
    /// LocalizationTests.dynamicFamilies, and verbStringKeys below).
    let verbSuffix: String
    let verbDefault: String
    /// Form -> the engine's effect dict. nil = too incomplete to serialize.
    let build: (RuleFormModel) -> [String: Any]?
    /// Stored effect dict -> the form's fields.
    let load: ([String: Any], inout RuleFormModel) -> Void
}

@MainActor
enum EffectKinds {
    /// Trim helper -- every field in this file is user-typed text.
    private static func t(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
    }

    static let all: [EffectKindSpec] = [
        EffectKindSpec(
            kind: "notify", verbSuffix: "notify", verbDefault: "notify",
            build: { m in
                let title = t(m.notifyTitle)
                guard !title.isEmpty else { return nil }
                var e: [String: Any] = ["kind": "notify", "title": title, "channel": m.notifyChannel]
                let body = t(m.notifyText)
                if !body.isEmpty { e["text"] = body }
                return e
            },
            load: { d, m in
                m.notifyTitle = d["title"] as? String ?? AppInfo.displayName
                m.notifyText = d["text"] as? String ?? ""
                m.notifyChannel = d["channel"] as? String ?? "app"
            }),

        EffectKindSpec(
            kind: "layout", verbSuffix: "layout", verbDefault: "arrange windows",
            build: { m in
                // Incomplete placements are DROPPED, not rejected: a half-filled row
                // in a list of good ones should not block the whole rule.
                let list: [[String: Any]] = m.placements.compactMap { p in
                    let app = t(p.app), screen = t(p.screen)
                    guard !app.isEmpty, !screen.isEmpty else { return nil }
                    var entry: [String: Any] = ["app": app, "screen": screen]
                    // A captured placement carries exact ratios; otherwise a named
                    // snap-grid id.
                    entry["pos"] = (p.pos == capturedPosId && p.ratios != nil) ? p.ratios! : p.pos
                    return entry
                }
                guard !list.isEmpty else { return nil }
                return ["kind": "layout", "placements": list]
            },
            load: { d, m in
                m.placements = ((d["placements"] as? [Any]) ?? [])
                    .compactMap { $0 as? [String: Any] }.map(Placement.init(from:))
            }),

        EffectKindSpec(
            kind: "runShortcut", verbSuffix: "runShortcut", verbDefault: "run Shortcut",
            build: { m in
                let n = t(m.shortcutName)
                guard !n.isEmpty else { return nil }
                return ["kind": "runShortcut", "name": n]
            },
            load: { d, m in m.shortcutName = d["name"] as? String ?? "" }),

        EffectKindSpec(
            kind: "openURL", verbSuffix: "open", verbDefault: "open",
            build: { m in
                let u = t(m.openURLValue)
                guard !u.isEmpty else { return nil }
                return ["kind": "openURL", "url": u]
            },
            load: { d, m in m.openURLValue = d["url"] as? String ?? "" }),

        EffectKindSpec(
            kind: "speak", verbSuffix: "speak", verbDefault: "say",
            build: { m in
                let s = t(m.speakText)
                guard !s.isEmpty else { return nil }
                return ["kind": "speak", "text": s]
            },
            load: { d, m in m.speakText = d["text"] as? String ?? "" }),

        EffectKindSpec(
            kind: "solidWallpaper", verbSuffix: "wallpaper", verbDefault: "set wallpaper",
            build: { m in
                let d = t(m.solidDisplay)
                guard !d.isEmpty else { return nil }
                return ["kind": "solidWallpaper", "color": m.solidColor, "display": d]
            },
            load: { d, m in
                m.solidColor = d["color"] as? String ?? "#FFFFFF"
                m.solidDisplay = d["display"] as? String ?? "external"
            }),

        EffectKindSpec(
            kind: "setWallpaperImage", verbSuffix: "wallpaper", verbDefault: "set wallpaper",
            build: { m in
                let img = t(m.wallpaperImage), disp = t(m.solidDisplay)
                guard !img.isEmpty, !disp.isEmpty else { return nil }
                return ["kind": "setWallpaperImage", "image": img, "display": disp]
            },
            load: { d, m in
                m.wallpaperImage = d["image"] as? String ?? ""
                m.solidDisplay = d["display"] as? String ?? "external"
            }),

        EffectKindSpec(
            kind: "moveAppToDisplay", verbSuffix: "move", verbDefault: "move",
            build: { m in
                let a = t(m.moveApp), disp = t(m.moveDisplay)
                guard !a.isEmpty, !disp.isEmpty else { return nil }
                var e: [String: Any] = ["kind": "moveAppToDisplay", "app": a, "display": disp]
                if !m.moveAppBundleId.isEmpty { e["appBundleId"] = m.moveAppBundleId }
                return e
            },
            load: { d, m in
                m.moveApp = d["app"] as? String ?? ""
                m.moveAppBundleId = d["appBundleId"] as? String ?? ""
                m.moveDisplay = d["display"] as? String ?? ""
            }),

        EffectKindSpec(
            kind: "launchApp", verbSuffix: "launchApp", verbDefault: "open",
            build: { m in
                // The bundle id is the launch key (required); the name rides along for
                // the sentence/log.
                let bid = t(m.launchAppBundleId), a = t(m.launchAppName)
                guard !bid.isEmpty, !a.isEmpty else { return nil }
                return ["kind": "launchApp", "app": a, "appBundleId": bid]
            },
            load: { d, m in
                m.launchAppName = d["app"] as? String ?? ""
                m.launchAppBundleId = d["appBundleId"] as? String ?? ""
            }),

        EffectKindSpec(
            kind: "setAppearance", verbSuffix: "appearance", verbDefault: "set appearance",
            build: { m in ["kind": "setAppearance", "mode": m.appearanceMode] },
            load: { d, m in m.appearanceMode = d["mode"] as? String ?? "dark" }),

        EffectKindSpec(
            kind: "volume", verbSuffix: "volume", verbDefault: "volume",
            build: { m in ["kind": "volume", "op": m.volumeOp] },
            load: { d, m in m.volumeOp = d["op"] as? String ?? "up" }),

        EffectKindSpec(
            kind: "mediaKey", verbSuffix: "media", verbDefault: "media",
            build: { m in ["kind": "mediaKey", "key": m.mediaKeyName] },
            load: { d, m in m.mediaKeyName = d["key"] as? String ?? "playpause" }),

        EffectKindSpec(
            kind: "chain", verbSuffix: "chain", verbDefault: "do several things",
            build: { m in
                // Drop incomplete steps (mirrors layout); keep order.
                let steps = m.chainSteps.compactMap { chainStepDict($0) }
                guard !steps.isEmpty else { return nil }
                return ["kind": "chain", "effects": steps]
            },
            load: { _, _ in
                // Chain rows are rebuilt by the view (chainStep(from:) filters to the
                // kinds the form can edit); a chain of un-editable kinds opens in JSON.
            }),
    ] + atomKinds

    /// Parameterless system atoms: identical in every respect but their name and
    /// verb, so they are generated rather than written out five times.
    private static let atomKinds: [EffectKindSpec] = [
        ("lockScreen", "lock", "lock the screen"),
        ("startScreensaver", "screensaver", "start the screensaver"),
        ("emptyTrash", "emptyTrash", "empty the Trash"),
        ("eject", "eject", "eject external disks"),
    ].map { kind, key, def in
        EffectKindSpec(kind: kind, verbSuffix: key, verbDefault: def,
                       build: { _ in ["kind": kind] },
                       load: { _, _ in })
    } + appTargetKinds.sorted().map { kind in
        // minimize / hide / quit: same shape, different verb.
        let (key, def): (String, String) = {
            switch kind {
            case "minimizeApp": return ("minimize", "minimize")
            case "hideApp":     return ("hide", "hide")
            default:            return ("quit", "quit")
            }
        }()
        return EffectKindSpec(
            kind: kind, verbSuffix: key, verbDefault: def,
            build: { m in
                let a = t(m.minimizeAppName)
                guard !a.isEmpty else { return nil }
                var e: [String: Any] = ["kind": kind, "app": a]
                if !m.minimizeAppBundleId.isEmpty { e["appBundleId"] = m.minimizeAppBundleId }
                return e
            },
            load: { d, m in
                m.minimizeAppName = d["app"] as? String ?? ""
                m.minimizeAppBundleId = d["appBundleId"] as? String ?? ""
            })
    }

    /// Every catalog key the verb pills can ask for. Declared to the localization
    /// gate as the "rules.verb." dynamic family, so a row whose verb has no
    /// translation is still caught -- moving these into a table must not make them
    /// invisible to the check that they exist.
    static var verbStringKeys: [String] { all.map { "rules.verb." + $0.verbSuffix } }

    private static let byKind: [String: EffectKindSpec] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })

    /// The row for `kind`, or nil for one this table does not cover -- today only
    /// "command", which is not a fixed kind at all (it names a feature + action
    /// resolved from the live catalog) and is handled by its callers.
    static func spec(for kind: String?) -> EffectKindSpec? {
        guard let kind else { return nil }
        return byKind[kind]
    }

    /// One chain step -> its dict, or nil when incomplete. Chain steps are a
    /// deliberately narrower set than `all` (the parameterless atoms plus the
    /// four single-field kinds); a chain containing anything else is edited as
    /// JSON, so this stays separate rather than recursing through the table.
    static func chainStepDict(_ s: ChainStep) -> [String: Any]? {
        switch s.kind {
        case "notify":
            let title = t(s.notifyTitle)
            guard !title.isEmpty else { return nil }
            var e: [String: Any] = ["kind": "notify", "title": title, "channel": s.notifyChannel]
            let body = t(s.notifyText)
            if !body.isEmpty { e["text"] = body }
            return e
        case "speak":
            let v = t(s.speakText)
            return v.isEmpty ? nil : ["kind": "speak", "text": v]
        case "runShortcut":
            let v = t(s.shortcutName)
            return v.isEmpty ? nil : ["kind": "runShortcut", "name": v]
        case "openURL":
            let v = t(s.url)
            return v.isEmpty ? nil : ["kind": "openURL", "url": v]
        case "lockScreen", "startScreensaver", "emptyTrash", "eject":
            return ["kind": s.kind]
        default:
            return nil
        }
    }
}
