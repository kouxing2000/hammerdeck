---
name: hammerdeck-visual-check
description: Screenshot and visually verify Hammerdeck's real pixels -- the Settings window, the Homepage/Gallery/Tour, the native panels (chooser, banner), the menubar menu, and the Hyper/chord hint cards. Use when verifying a UI change in the live app, capturing a config-UI form or trigger/chord editor, iterating on panel or menubar layout, or whenever a change needs "does it actually look right" confirmation that tests cannot give. Reach for this BEFORE driving the live window with osascript clicks or scrolls.
---

# Visually verifying Hammerdeck

Tests cannot check pixels. This is the loop that can.

Start the app with a debug control channel, then drive and capture:

```bash
scripts/app.sh start          # sets HAMMERDECK_CONTROL_DIR; DebugControl starts
scripts/control.sh '<lua>'    # run Lua in the live app (e.g. open the palette)
scripts/control.sh '@<cmd>'   # host-UI commands the Lua eval cannot reach
```

## `control.sh` is SINGLE-USER -- never batch it in parallel

One command at a time. The file handshake (`cmd.lua` / `result.txt`) has no
request/response correlation id, so two concurrent callers can hand each other's
answers back or strand a command entirely. A lock enforces it: a second caller
exits non-zero with `another control.sh (PID N) is mid-request`.

This bites agents specifically, because the default habit is to batch
independent commands into one parallel block. **Run every `control.sh` call
sequentially**, including an `@settings:` followed by its `@shot:`.

## Which capture tool

Three capture paths, not two. Picking the wrong one is the usual time sink.

| Target | Tool | Permissions needed |
|---|---|---|
| **Settings window / Homepage** (option forms, chord+trigger editors, gallery) | `scripts/control.sh '@shot:<path>'` | none |
| **Native panels** (chooser, banner, hint cards) | `scripts/shot.sh out.png` | Screen Recording |
| **Menubar menu** (the status-bar popup) | `scripts/menu-shot.sh out.png` | Screen Recording **+** Accessibility |

`@shot` cannot reach the native panels: they are `FloatingPanel: NSPanel` and
`DebugShot.targetWindow()` filters `NSPanel` out.

`scripts/shot.sh` cannot reliably frame the **menubar menu** -- it is a transient
popup that flashes, toggles closed, and shifts position with the other menu
extras. `menu-shot.sh` asks Accessibility for the open menu's exact rect and
feeds it to `screencapture -R`, so no crop offsets are guessed. Default output
`/tmp/hammerdeck-menu.png`. If two Hammerdeck instances are running you may
capture a stale menu -- `pgrep -lf debug/Hammerdeck` and kill the extra first.

`scripts/shot.sh` waits `HD_SHOT_DELAY` (default `0.4`s) for the panel to finish
drawing. Bump it (`HD_SHOT_DELAY=0.6`) if you capture mid-animation.

## Host-UI commands (`DebugControl`, DEBUG-only)

The Lua eval channel cannot reach host UI. These six can. All are intercepted
before the Lua eval; the whole channel is inside `#if DEBUG` with a release no-op.

| Command | Effect |
|---|---|
| `@settings` | open the Settings tab |
| `@settings:<featureId>` | open Settings straight to that feature's detail (e.g. `@settings:count_down`) |
| `@home[:features\|shortcuts\|rules\|timeline\|home]` | open the Homepage, optionally on a tab |
| `@tour` | present the first-run Feature Tour |
| `@hyperhint` | **toggle** the Hyper which-key legend (there is no Caps release to dismiss it) |
| `@chordhint` | **toggle** the chord which-key hint card (no armed chord to time it out) |
| `@shot[:<path>]` | in-process self-capture; default `/tmp/hammerdeck-shot.png` |

`@home` / `@tour` are the ONLY route to Homepage / Gallery / Tour pixels. The
two hint commands exist precisely because those cards have no dismissal you
could otherwise time a capture against -- do not try to synthesize a Caps hold.

## `@shot`: what it does, and its two traps

The app renders the window's widest scroll-view document to a PNG in-process
(`DebugShot`). That is why it needs **no Screen Recording**, does not care
whether the window is frontmost / occluded / off-screen, and captures the
scroll view's **FULL content height** -- options below the fold (long forms, an
expanded row editor) are included without scrolling.

It returns `shot <W>x<H> blank=<bool> -> <path>`. **Read that line.** `blank=true`
is the built-in "this capture failed" signal (the classic layer-backed
`cacheDisplay` failure); don't open the PNG expecting content.

**Trap 1 -- it captures the KEY window, not necessarily Settings.**
`targetWindow()` picks the key visible main-capable non-panel window, falling
back to the first candidate. With both the Homepage and Settings open, `@shot`
can silently capture the wrong one. Bring the one you want to key first
(`@settings:<id>` or `@home`), sequentially, then `@shot`.

**Trap 2 -- in DARK mode the capture is unreadable.** It comes out
white-text-on-a-light-bitmap: `cacheDisplay` re-rasterizes SwiftUI's
already-resolved dark colors, and forcing the NSView's `.appearance` does NOT
re-resolve them. Workaround: put the APP in light for the shot and restore
after -- Settings > General > App > Appearance = Light. Flipping the whole
system via `adapter.setAppearance("light")` also works, but ONLY while that
preference is "system"; a pinned app appearance ignores the system, so that
route silently no-ops for anyone who chose Light or Dark.

## Why this skill exists

Driving the live Settings window via osascript clicks/scrolls is a rabbit hole
-- focus theft, below-the-fold content you never see, and a slow loop that makes
every pixel question expensive. In-process self-capture sidesteps all of it.
Reach for `@shot` BEFORE blind-iterating on config-UI pixels.

Once the loop is fast and reliable, `CLAUDE.md`'s "Pixel fixes -- probe before
iterating" rule governs what to do with what you see: a native-AppKit fix that
misses once is usually a HARD constraint, not one tweak away.
