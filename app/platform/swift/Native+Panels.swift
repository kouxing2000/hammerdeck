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
        // Optional screen rect (args 2-5, top-left global points): pin the
        // banner to that screen's top edge instead of NSScreen.main's.
        var screen: NSRect?
        if let x = LuaState.double(L, 2), let y = LuaState.double(L, 3),
           let w = LuaState.double(L, 4), let h = LuaState.double(L, 5) {
            let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
            screen = NSRect(x: x, y: primaryMaxY - (y + h), width: w, height: h)
        }
        let banner = BannerPanel(text: LuaState.string(L, 1) ?? "", screen: screen)
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

    func chooserSetTitle(_ L: OpaquePointer?) -> Int32 {
        chooser(L)?.setTitle(LuaState.string(L, 2) ?? "",
                             symbol: LuaState.string(L, 3),
                             badge: LuaState.string(L, 4))
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
        // actions arrive as { text =, image = <icon token> } dicts (the adapter
        // normalizes plain-string actions into this shape too).
        let actions = LuaState.dictArray(L, 3)
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
        let entries = actions.map { d in
            ChooserEntry(text: d["text"] as? String ?? "", subText: nil,
                         iconToken: d["image"] as? String, valid: true)
        }
        panel.setChoices(entries)
        panel.setTitle(title)        // real header band, not the dim search placeholder
        panel.setFooter(infos)       // pinned context strip, not blurred-in list rows
        panel.setSearchHidden(true)  // fixed-choice dialog: an empty search box is just noise
        panel.show()

        cancellers[id] = {
            if !done {
                done = true
                Native.shared.lua.releaseRef(ref)
            }
            // Deferred for the same reason as askWindows' canceller below: a
            // one-shot caller's h.stop() inside its own onChoose runs this
            // while the panel's finish frame is still on the stack -- the
            // async block keeps the last strong reference alive past it.
            DispatchQueue.main.async { panel.close() }
        }
        choosers[id] = panel
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    func askChoiceDismiss(_ L: OpaquePointer?) -> Int32 {
        chooser(L)?.select(0)   // out-of-range select = finish(nil) = cancelled
        return 0
    }

    // MARK: - askWindows (one-shot multi-select, built on WindowPickerPanel)

    func askWindows(_ L: OpaquePointer?) -> Int32 {
        let title = LuaState.string(L, 1) ?? ""
        let items = LuaState.dictArray(L, 2)
        let minPick = LuaState.int(L, 3) ?? 1
        let palette = LuaState.stringArray(L, 4)   // color-cycle order; empty = no swatches
        let ref = lua.makeRef(at: 5)
        // Opt-in hero row: a non-empty label adds a switch (the deck's Hero mode);
        // empty = a plain picker. `heroOn` is its initial state.
        let heroLabel = LuaState.string(L, 6) ?? ""
        let heroOn = LuaState.bool(L, 7) ?? true
        // Optional screen rect (args 8-11, top-left global points): center the
        // picker on that screen (the deck's picked display) instead of the
        // key window's screen.
        var screen: NSRect?
        if let x = LuaState.double(L, 8), let y = LuaState.double(L, 9),
           let w = LuaState.double(L, 10), let h = LuaState.double(L, 11) {
            let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
            screen = NSRect(x: x, y: primaryMaxY - (y + h), width: w, height: h)
        }

        let id = allocId()
        var done = false
        let entries = items.map { d in
            WindowPickerEntry(text: d["text"] as? String ?? "",
                              subText: d["subText"] as? String,
                              iconToken: d["image"] as? String,
                              color: d["color"] as? String ?? "")
        }
        let panel = WindowPickerPanel(title: title, entries: entries, minPick: minPick,
                                      palette: palette, heroLabel: heroLabel, heroOn: heroOn) { picked, colors, hero in
            guard !done else { return }
            done = true
            Native.shared.lua.callRef(ref) { L in
                guard let picked else { lua_pushnil(L); return 1 }
                // 1-based checked indices as a Lua array; the adapter maps them
                // back to the original choice tables it kept Lua-side.
                lua_createtable(L, Int32(picked.count), 0)
                for (i, idx) in picked.enumerated() {
                    lua_pushinteger(L, lua_Integer(idx))
                    lua_rawseti(L, -2, lua_Integer(i + 1))
                }
                // ...plus the (possibly recolored) per-row colors, aligned 1..n
                // with ALL entries, so the adapter can update each kept item.
                lua_createtable(L, Int32(colors.count), 0)
                for (i, hex) in colors.enumerated() {
                    lua_pushstring(L, hex)
                    lua_rawseti(L, -2, lua_Integer(i + 1))
                }
                lua_pushboolean(L, hero ? 1 : 0)   // the Hero switch state
                return 3
            }
            Native.shared.lua.releaseRef(ref)
            Native.shared.freeResource(id)
        }
        panel.show(on: screen)

        cancellers[id] = {
            if !done {
                done = true
                Native.shared.lua.releaseRef(ref)
            }
            // This canceller commonly runs FROM the panel's own completion
            // (Lua's onChoose calls h.stop() -- the documented one-shot
            // pattern), i.e. while the panel's finish() frame is still on the
            // stack. Deferring the close one runloop turn keeps the closure's
            // strong reference alive past that frame, so the self-free can
            // never deallocate an object that is still executing.
            DispatchQueue.main.async { panel.close() }
        }
        windowPickers[id] = panel
        lua_pushinteger(L, lua_Integer(id))
        return 1
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
            // Deferred close: see the askWindows canceller (self-free while
            // the panel's own finish frame is still on the stack).
            DispatchQueue.main.async { panel.close() }
        }
        askTexts[id] = panel
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    func askTextDismiss(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init) { askTexts[id]?.dismiss() }
        return 0
    }

    // MARK: - Outline (click-through accent border overlays: member/hero/ghost)

    func outlineShow(_ L: OpaquePointer?) -> Int32 {
        let panel = OutlinePanel(kind: LuaState.string(L, 1) ?? "member",
                                 colorHex: LuaState.string(L, 2) ?? "")
        let id = registerResource { panel.close() }
        outlines[id] = panel
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    func outlineSetColor(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init), let hex = LuaState.string(L, 2) {
            outlines[id]?.setColor(hex)
        }
        return 0
    }

    func outlineSetFrame(_ L: OpaquePointer?) -> Int32 {
        guard let id = LuaState.int(L, 1).map(Int32.init),
              let panel = outlines[id],
              let x = LuaState.double(L, 2), let y = LuaState.double(L, 3),
              let w = LuaState.double(L, 4), let h = LuaState.double(L, 5) else { return 0 }
        // top-left global points -> AppKit bottom-left (same flip axRect uses).
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        panel.place(NSRect(x: x, y: primaryMaxY - (y + h), width: w, height: h))
        return 0
    }

    func outlineSetStyle(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init), let kind = LuaState.string(L, 2) {
            outlines[id]?.setStyle(kind)
        }
        return 0
    }

    func outlineAnimateFrame(_ L: OpaquePointer?) -> Int32 {
        guard let id = LuaState.int(L, 1).map(Int32.init), let panel = outlines[id],
              let x = LuaState.double(L, 2), let y = LuaState.double(L, 3),
              let w = LuaState.double(L, 4), let h = LuaState.double(L, 5) else { return 0 }
        let dur = LuaState.double(L, 6) ?? 0.15
        // top-left global points -> AppKit bottom-left (same flip axRect uses).
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        panel.animateTo(NSRect(x: x, y: primaryMaxY - (y + h), width: w, height: h),
                        duration: dur)
        return 0
    }

    func outlineHide(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init) { outlines[id]?.hide() }
        return 0
    }

    func outlineSetHole(_ L: OpaquePointer?) -> Int32 {
        guard let id = LuaState.int(L, 1).map(Int32.init), let panel = outlines[id] else { return 0 }
        guard let x = LuaState.double(L, 2), let y = LuaState.double(L, 3),
              let w = LuaState.double(L, 4), let h = LuaState.double(L, 5) else {
            panel.setHole(nil)   // no rect args = clear the hole
            return 0
        }
        // top-left global points -> AppKit bottom-left (same flip axRect uses).
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        panel.setHole(NSRect(x: x, y: primaryMaxY - (y + h), width: w, height: h))
        return 0
    }

    // MARK: - Scrim (Window Deck dim + hole-punched container; replaces the banner)

    // Flip a top-left global rect to AppKit bottom-left (same flip axRect uses).
    private func flipToAppKit(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NSRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: x, y: primaryMaxY - (y + h), width: w, height: h)
    }

    func scrimShow(_ L: OpaquePointer?) -> Int32 {
        var screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let x = LuaState.double(L, 1), let y = LuaState.double(L, 2),
           let w = LuaState.double(L, 3), let h = LuaState.double(L, 4) {
            screen = flipToAppKit(x, y, w, h)
        }
        let dim = CGFloat(LuaState.double(L, 5) ?? 0.5)
        let scrim = ScrimPanel(screen: screen, dim: dim)
        let id = registerResource { scrim.close() }
        scrims[id] = scrim
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    // scrim_set_holes(id, {{x,y,w,h}, ...}) -- top-left global rects.
    func scrimSetHoles(_ L: OpaquePointer?) -> Int32 {
        guard let id = LuaState.int(L, 1).map(Int32.init), let scrim = scrims[id] else { return 0 }
        let rects = LuaState.dictArray(L, 2).compactMap { d -> NSRect? in
            guard let x = d["x"] as? Double, let y = d["y"] as? Double,
                  let w = d["w"] as? Double, let h = d["h"] as? Double else { return nil }
            return flipToAppKit(x, y, w, h)
        }
        scrim.setHoles(rects)
        return 0
    }

    func scrimSetDim(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init), let d = LuaState.double(L, 2) {
            scrims[id]?.setDim(CGFloat(d))
        }
        return 0
    }

    func scrimReanchor(_ L: OpaquePointer?) -> Int32 {
        guard let id = LuaState.int(L, 1).map(Int32.init), let scrim = scrims[id],
              let x = LuaState.double(L, 2), let y = LuaState.double(L, 3),
              let w = LuaState.double(L, 4), let h = LuaState.double(L, 5) else { return 0 }
        scrim.reanchor(flipToAppKit(x, y, w, h))
        return 0
    }

    func scrimHide(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init) { scrims[id]?.hide() }
        return 0
    }

    func scrimShowAgain(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init) { scrims[id]?.show() }
        return 0
    }

    // MARK: - Deck widget (draggable control card: title + Exit + mini-map)

    // deck_widget_show(opts) -- opts is a single table (safer than ~20 positional
    // args). Fields: title, hint, name, switchHint, heroLabel, exitLabel,
    // rearrangeLabel (all strings); x, y (top-left global corner); sx, sy, sw, sh
    // (deck screen, the drag clamp); gridCols + colors[] build the mini-map
    // (row-major, 1-based); heroIndex lights a cell (0 = none); heroOn = initial
    // Hero toggle state; onMove(x,y) / onExit() / onSwitch(i) / onToggleHero(bool)
    // / onRearrange() callbacks.
    func deckWidgetShow(_ L: OpaquePointer?) -> Int32 {
        // Field readers over the opts table at stack index 1. makeRef is
        // stack-neutral (it pushes a copy then luaL_refs it), so getfield ->
        // makeRef(at:-1) -> pop reads a callback cleanly.
        func str(_ k: String) -> String {
            lua_getfield(L, 1, k); defer { lua_settop(L, -2) }; return LuaState.string(L, -1) ?? ""
        }
        func dbl(_ k: String, _ d: Double) -> Double {
            lua_getfield(L, 1, k); defer { lua_settop(L, -2) }; return LuaState.double(L, -1) ?? d
        }
        func i32(_ k: String, _ d: Int) -> Int {
            lua_getfield(L, 1, k); defer { lua_settop(L, -2) }; return LuaState.int(L, -1).map { Int($0) } ?? d
        }
        func flag(_ k: String, _ d: Bool) -> Bool {
            lua_getfield(L, 1, k); defer { lua_settop(L, -2) }; return LuaState.bool(L, -1) ?? d
        }
        func ref(_ k: String) -> Int32 {
            lua_getfield(L, 1, k); defer { lua_settop(L, -2) }; return lua.makeRef(at: -1)
        }
        var colors: [String] = []
        lua_getfield(L, 1, "colors")
        if lua_type(L, -1) == LUA_TTABLE {
            let n = lua_rawlen(L, -1)
            if n > 0 { for i in 1...n {
                lua_rawgeti(L, -1, lua_Integer(i)); colors.append(LuaState.string(L, -1) ?? ""); lua_settop(L, -2)
            } }
        }
        lua_settop(L, -2)

        let moveRef = ref("onMove"), exitRef = ref("onExit"), switchRef = ref("onSwitch")
        let toggleRef = ref("onToggleHero"), rearrangeRef = ref("onRearrange")
        let widget = DeckWidgetPanel(
            title: str("title"), hint: str("hint"), displayName: str("name"),
            switchHint: str("switchHint"), heroLabel: str("heroLabel"),
            exitLabel: str("exitLabel"), rearrangeLabel: str("rearrangeLabel"),
            gridCols: i32("gridCols", 2), heroIndex: i32("heroIndex", 0),
            cellColors: colors, heroOn: flag("heroOn", true),
            topLeft: CGPoint(x: dbl("x", 20), y: dbl("y", 20)),
            screen: flipToAppKit(dbl("sx", 0), dbl("sy", 0), dbl("sw", 1440), dbl("sh", 900)),
            onMove: { nx, ny in
                Native.shared.lua.callRef(moveRef) { L in
                    lua_pushnumber(L, nx); lua_pushnumber(L, ny); return 2
                }
            },
            onExit: { Native.shared.lua.callRef(exitRef) },
            onSwitch: { idx in
                Native.shared.lua.callRef(switchRef) { L in
                    lua_pushinteger(L, lua_Integer(idx)); return 1
                }
            },
            onToggleHero: { on in
                Native.shared.lua.callRef(toggleRef) { L in
                    lua_pushboolean(L, on ? 1 : 0); return 1
                }
            },
            onRearrange: { Native.shared.lua.callRef(rearrangeRef) })
        // Release all five pinned Lua callbacks on teardown, then close -- same
        // as askWindows/askText/chooser cancellers (a bare widget.close() would
        // strand the refs in the Lua registry every deck cycle).
        let id = registerResource {
            Native.shared.lua.releaseRef(moveRef)
            Native.shared.lua.releaseRef(exitRef)
            Native.shared.lua.releaseRef(switchRef)
            Native.shared.lua.releaseRef(toggleRef)
            Native.shared.lua.releaseRef(rearrangeRef)
            widget.close()
        }
        deckWidgets[id] = widget
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    func deckWidgetSetHero(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init), let idx = LuaState.int(L, 2) {
            deckWidgets[id]?.setHero(Int(idx))
        }
        return 0
    }

    func deckWidgetSetSwitchHint(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init) {
            deckWidgets[id]?.setSwitchHint(LuaState.string(L, 2) ?? "")
        }
        return 0
    }

    func deckWidgetSetDirty(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init) {
            deckWidgets[id]?.setDirty(LuaState.bool(L, 2) ?? false)
        }
        return 0
    }

    // deck_widget_reanchor(id, x, y, sx, sy, sw, sh) -- reposition + re-clamp.
    func deckWidgetReanchor(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init),
           let x = LuaState.double(L, 2), let y = LuaState.double(L, 3),
           let sx = LuaState.double(L, 4), let sy = LuaState.double(L, 5),
           let sw = LuaState.double(L, 6), let sh = LuaState.double(L, 7) {
            deckWidgets[id]?.reanchor(topLeft: CGPoint(x: x, y: y),
                                      screen: flipToAppKit(sx, sy, sw, sh))
        }
        return 0
    }

    func deckWidgetHide(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init) { deckWidgets[id]?.hide() }
        return 0
    }

    func deckWidgetShowAgain(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init) { deckWidgets[id]?.show() }
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
