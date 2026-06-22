// Native.swift split: this file is one domain slice of the `Native`
// seam (see Native.swift for the class, shared state, and installBindings).
// User-facing output + panels: alerts, banner, chooser, dialogs, progress, usage widget.

import AppKit
import CLua

extension Native {
    // MARK: - Output

    func notify(_ L: OpaquePointer?) -> Int32 {
        Toast.show(title: LuaState.string(L, 1), text: LuaState.string(L, 2) ?? "",
                   centered: false, seconds: 5)
        return 0
    }

    func alert(_ L: OpaquePointer?) -> Int32 {
        Toast.show(title: nil, text: LuaState.string(L, 1) ?? "",
                   centered: true, seconds: 2)
        return 0
    }

    // MARK: - Banner

    func bannerShow(_ L: OpaquePointer?) -> Int32 {
        let banner = BannerPanel(text: LuaState.string(L, 1) ?? "")
        let id = registerResource { banner.close() }
        banners[id] = banner
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    func bannerSetText(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init), let text = LuaState.string(L, 2) {
            banners[id]?.setText(text)
        }
        return 0
    }

    // MARK: - Window Mode HUD (structured cheat-sheet card)

    func hudShow(_ L: OpaquePointer?) -> Int32 {
        let dict = LuaState.any(L, 1) as? [String: Any] ?? [:]
        let hud = WindowModeHUDPanel(spec: WindowModeHUDPanel.Spec(dict))
        let id = registerResource { hud.close() }
        windowModeHUDs[id] = hud
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    // MARK: - Chooser

    func chooserNew(_ L: OpaquePointer?) -> Int32 {
        let searchSubText = LuaState.bool(L, 1)
        let selectRef = lua.makeRef(at: 2)
        let hideRef = lua.makeRef(at: 3)
        let panel = ChooserPanel(
            searchSubText: searchSubText,
            onSelect: { idx in
                Native.shared.lua.callRef(selectRef) { L in
                    if let idx { lua_pushinteger(L, lua_Integer(idx)) } else { lua_pushnil(L) }
                    return 1
                }
            },
            onHide: { Native.shared.lua.callRef(hideRef) }
        )
        let id = registerResource {
            panel.close()
            Native.shared.lua.releaseRef(selectRef)
            Native.shared.lua.releaseRef(hideRef)
        }
        choosers[id] = panel
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    private func chooser(_ L: OpaquePointer?) -> ChooserPanel? {
        guard let id = LuaState.int(L, 1).map(Int32.init) else { return nil }
        return choosers[id]
    }

    func chooserSetChoices(_ L: OpaquePointer?) -> Int32 {
        guard let panel = chooser(L) else { return 0 }
        let entries = LuaState.dictArray(L, 2).map { d in
            ChooserEntry(text: d["text"] as? String ?? "",
                         subText: d["subText"] as? String,
                         iconToken: d["image"] as? String,
                         valid: (d["valid"] as? Bool) ?? true,
                         shortcut: d["shortcut"] as? String)
        }
        panel.setChoices(entries)
        return 0
    }

    func chooserSetPlaceholder(_ L: OpaquePointer?) -> Int32 {
        chooser(L)?.setPlaceholder(LuaState.string(L, 2) ?? "")
        return 0
    }

    func chooserSetQuery(_ L: OpaquePointer?) -> Int32 {
        chooser(L)?.setQuery(LuaState.string(L, 2))
        return 0
    }

    func chooserShow(_ L: OpaquePointer?) -> Int32 {
        chooser(L)?.show()
        return 0
    }

    func chooserHide(_ L: OpaquePointer?) -> Int32 {
        chooser(L)?.hide()
        return 0
    }

    func chooserVisible(_ L: OpaquePointer?) -> Int32 {
        lua_pushboolean(L, (chooser(L)?.isVisible ?? false) ? 1 : 0)
        return 1
    }

    func chooserSelectedRow(_ L: OpaquePointer?) -> Int32 {
        lua_pushinteger(L, lua_Integer(chooser(L)?.selectedRow() ?? 0))
        return 1
    }

    func chooserSetSelectedRow(_ L: OpaquePointer?) -> Int32 {
        if let n = LuaState.int(L, 2) { chooser(L)?.setSelectedRow(n) }
        return 0
    }

    func chooserSelect(_ L: OpaquePointer?) -> Int32 {
        if let n = LuaState.int(L, 2) { chooser(L)?.select(n) }
        return 0
    }

    // MARK: - UI introspection (TEST-ONLY)
    //
    // A read-only window into the live native panels, for `swift test`. This is
    // deliberately NOT surfaced through the adapter / ctx: a feature must never
    // be able to enumerate or drive another feature's panels (same
    // least-privilege reasoning as the `commands` capability gate). Tests reach
    // it via `@testable import HammerdeckKit`; the headless Lua suite uses the
    // fake adapter's own chooser introspection instead. Keeping it here means
    // the "real panel" assertions an agent/CI needs live in one obvious place.

    /// A snapshot of one live chooser panel's state. `id` is stable across a
    /// feature's repeat invocations (a feature reuses its chooser), so a test
    /// can follow a single chooser through opens/closes.
    struct ChooserSnapshot {
        let id: Int32
        let visible: Bool
        let isKey: Bool
        let placeholder: String
        let rowCount: Int
        let selectedRow: Int
        let entries: [String]
    }

    /// Every live chooser's state, id-sorted.
    func chooserSnapshots() -> [ChooserSnapshot] {
        choosers.map { id, p in
            ChooserSnapshot(id: id, visible: p.isVisible, isKey: p.isKey,
                            placeholder: p.placeholder, rowCount: p.visibleRowCount,
                            selectedRow: p.selectedRow(), entries: p.visibleEntryTexts)
        }.sorted { $0.id < $1.id }
    }

    /// Just the visible choosers (the common assertion target).
    func visibleChoosers() -> [ChooserSnapshot] {
        chooserSnapshots().filter(\.visible)
    }

    /// Drive a chooser's selection as the user would (fires its onSelect), by
    /// the id a snapshot reported -- so a test can pick a row without
    /// synthesizing a keystroke or a click. `row` is 1-based into the visible list.
    func selectChooserRow(id: Int32, row: Int) {
        choosers[id]?.select(row)
    }

    // MARK: - askChoice (one-shot dialog built on ChooserPanel)

    func askChoice(_ L: OpaquePointer?) -> Int32 {
        let title = LuaState.string(L, 1) ?? ""
        let infos = LuaState.stringArray(L, 2)
        let actions = LuaState.stringArray(L, 3)
        let ref = lua.makeRef(at: 4)

        let id = allocId()
        var done = false
        let panel = ChooserPanel(
            searchSubText: false,
            onSelect: { idx in
                guard !done else { return }
                done = true
                let actionIdx = (idx != nil && idx! <= actions.count) ? idx : nil
                Native.shared.lua.callRef(ref) { L in
                    if let a = actionIdx { lua_pushinteger(L, lua_Integer(a)) } else { lua_pushnil(L) }
                    return 1
                }
                Native.shared.lua.releaseRef(ref)
                Native.shared.freeResource(id)
            },
            onHide: {}
        )
        var entries = actions.map { ChooserEntry(text: $0, subText: nil, iconToken: nil, valid: true) }
        entries += infos.map { ChooserEntry(text: $0, subText: nil, iconToken: nil, valid: false) }
        panel.setChoices(entries)
        panel.setPlaceholder(title)
        panel.show()

        cancellers[id] = {
            if !done {
                done = true
                Native.shared.lua.releaseRef(ref)
            }
            panel.close()
        }
        choosers[id] = panel
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    func askChoiceDismiss(_ L: OpaquePointer?) -> Int32 {
        chooser(L)?.select(0)   // out-of-range select = finish(nil) = cancelled
        return 0
    }

    // MARK: - askText (one-shot text prompt)

    func askText(_ L: OpaquePointer?) -> Int32 {
        let title = LuaState.string(L, 1) ?? ""
        let placeholder = LuaState.string(L, 2) ?? ""
        let defaultValue = LuaState.string(L, 3) ?? ""
        let ref = lua.makeRef(at: 4)

        let id = allocId()
        var done = false
        let panel = AskTextPanel(title: title, placeholder: placeholder,
                                 defaultValue: defaultValue) { text in
            guard !done else { return }
            done = true
            Native.shared.lua.callRef(ref) { L in
                if let text { lua_pushstring(L, text) } else { lua_pushnil(L) }
                return 1
            }
            Native.shared.lua.releaseRef(ref)
            Native.shared.freeResource(id)
        }
        cancellers[id] = {
            if !done {
                done = true
                Native.shared.lua.releaseRef(ref)
            }
            panel.close()
        }
        askTexts[id] = panel
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    func askTextDismiss(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init) { askTexts[id]?.dismiss() }
        return 0
    }

    // MARK: - Progress strip

    func progressShow(_ L: OpaquePointer?) -> Int32 {
        let panel = ProgressPanel()
        let id = registerResource { panel.close() }
        progresses[id] = panel
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    func progressSet(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init), let f = LuaState.double(L, 2) {
            progresses[id]?.setProgress(f)
        }
        return 0
    }

    // MARK: - Usage widget (desktop-pinned stats card)

    func usageWidgetShow(_ L: OpaquePointer?) -> Int32 {
        let panel = UsageWidgetPanel(screenIndex: LuaState.int(L, 1) ?? 1)
        let id = registerResource { panel.close() }
        widgets[id] = panel
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    func usageWidgetSet(_ L: OpaquePointer?) -> Int32 {
        guard let id = LuaState.int(L, 1).map(Int32.init),
              let dict = LuaState.any(L, 2) as? [String: Any],
              let data = UsageWidgetData(dict) else { return 0 }
        widgets[id]?.setData(data)
        return 0
    }
}
