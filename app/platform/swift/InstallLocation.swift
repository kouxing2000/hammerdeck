import AppKit
import SwiftUI

/// First-launch install-location guard.
///
/// An app that macOS QUARANTINED (anything a browser downloaded) is
/// TRANSLOCATED when it is launched from wherever it was unarchived: macOS runs
/// it from a randomised read-only path, and Sparkle can then never install an
/// update. The app works, and simply never offers a new version again --
/// silently, for the life of that copy.
///
/// Only a move performed in FINDER clears the quarantine flag; a copy from a
/// terminal does not. So an app that wants to stay updatable has to notice where
/// it is running from and offer to move itself.
///
/// This is HOST LIFECYCLE, deliberately absent from `ctx` -- the same category as
/// the updater and the Dock policy. A feature has no business relocating the app.
@MainActor
enum InstallLocation {

    // MARK: - Deciding whether to ask

    /// The user declined once; do not ask again on every launch. Kept per
    /// INSTALL rather than forever: a fresh download is a fresh decision, and
    /// this key travels with the defaults domain, not with the bundle.
    private static let declinedKey = "hammerdeck.installLocation.declined"

    /// Where a correctly installed copy lives. `~/Applications` counts -- it is a
    /// real install location and nothing about it breaks updating.
    private static var applicationsRoots: [String] {
        ["/Applications", NSHomeDirectory() + "/Applications"]
    }

    /// Only a PACKAGED build can update itself, so only a packaged build has a
    /// reason to care where it lives. `SUFeedURL` is written into Info.plist by
    /// scripts/package.sh, which makes it the same "am I a real build?" signal
    /// `Updater` already branches on -- one fact, read the same way twice, rather
    /// than a second heuristic that can disagree with it.
    private static var isPackaged: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    /// The path the user actually put the app at. For a translocated bundle that
    /// is NOT `Bundle.main.bundleURL` -- that one is the disposable copy macOS
    /// made. Moving the disposable copy would leave the real one in Downloads and
    /// fix nothing, so the original has to be resolved first.
    ///
    /// The two Security calls are reached through `dlsym`: they are C functions in
    /// Security.framework with no Swift overlay, and a bridging header for two
    /// symbols would cost more than it explains. A missing symbol degrades to
    /// "not translocated", which is the safe answer -- it means we offer to move
    /// the bundle we can see, and at worst the offer does nothing useful.
    private static func realBundleURL() -> URL {
        let here = Bundle.main.bundleURL
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else {
            return here
        }
        defer { dlclose(handle) }

        typealias IsTranslocatedFn = @convention(c)
            (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        typealias OriginalPathFn = @convention(c)
            (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

        guard let isSym = dlsym(handle, "SecTranslocateIsTranslocatedURL"),
              let origSym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return here }

        var translocated = false
        var error: Unmanaged<CFError>?
        let ok = unsafeBitCast(isSym, to: IsTranslocatedFn.self)(here as CFURL, &translocated, &error)
        guard ok, translocated else { return here }

        var origError: Unmanaged<CFError>?
        guard let original = unsafeBitCast(origSym, to: OriginalPathFn.self)(here as CFURL, &origError) else {
            return here
        }
        return original.takeRetainedValue() as URL
    }

    /// Is this copy in a place where it can keep itself up to date?
    private static func isWellPlaced(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return applicationsRoots.contains { path.hasPrefix($0 + "/") }
    }

    // MARK: - Entry point

    /// Called once at launch, BEFORE the Lua platform boots. Returns `true` when
    /// the process is about to be replaced by a relaunched copy, in which case the
    /// caller must stop -- booting features into a process that is exiting would
    /// grab hotkeys and start timers for the few hundred milliseconds it survives.
    static func promptIfNeeded() -> Bool {
        guard isPackaged,
              ProcessInfo.processInfo.environment["HAMMERDECK_NO_MOVE_PROMPT"] == nil,
              !UserDefaults.standard.bool(forKey: declinedKey) else { return false }

        let real = realBundleURL()
        guard !isWellPlaced(real) else { return false }

        switch runPanel() {
        case .move:
            return move(from: real)
        case .decline:
            UserDefaults.standard.set(true, forKey: declinedKey)
            return false
        }
    }

    // MARK: - The move

    /// The bundle to install, on a volume we are allowed to take it from.
    ///
    /// Both routes below consume their source -- `moveItem` by definition, and
    /// `replaceItemAt` because it swaps the item in rather than duplicating it --
    /// so neither can run against a read-only volume. That is the normal case for
    /// a DMG: double-clicking the app inside the mounted image is the commonest
    /// way to launch it, and the whole install prompt would then fail with a
    /// permissions error at the one moment it exists to be useful.
    ///
    /// The temporary directory is requested `appropriateFor: target`, which puts
    /// it on the destination volume, so the move that follows is a rename rather
    /// than a second copy of the whole bundle.
    private static func stagedForInstall(_ source: URL, target: URL) throws -> URL {
        let readOnly = (try? source.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?
            .volumeIsReadOnly ?? false
        guard readOnly else { return source }

        let fm = FileManager.default
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: target, create: true)
        let copy = scratch.appendingPathComponent(source.lastPathComponent)
        try fm.copyItem(at: source, to: copy)
        return copy
    }

    /// Move, strip the quarantine flag, relaunch, exit.
    ///
    /// Clearing `com.apple.quarantine` is the load-bearing step, not tidiness: the
    /// flag is what makes macOS translocate on the NEXT launch, so a move that
    /// leaves it set relocates the app and changes nothing about the problem.
    /// Finder clears it when a person drags; nothing clears it for us.
    private static func move(from source: URL) -> Bool {
        let target = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(source.lastPathComponent)
        let fm = FileManager.default

        do {
            let staged = try stagedForInstall(source, target: target)
            // The scratch copy is a whole app bundle. Both routes below CONSUME
            // it on success, but on the error path it is left behind -- and the
            // DMG case is exactly where the move can fail (a managed volume, a
            // root-owned /Applications), so pressing Move again next launch
            // would orphan another copy.
            defer {
                if staged != source {
                    try? fm.removeItem(at: staged.deletingLastPathComponent())
                }
            }
            if fm.fileExists(atPath: target.path) {
                // Replacing a copy that is not running: the one running IS this
                // process only when it was launched from /Applications, and that
                // case never reaches here (isWellPlaced would have returned true).
                _ = try fm.replaceItemAt(target, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: target)
            }
        } catch {
            // A failed move is not fatal -- the app runs fine from where it is, it
            // just cannot update itself. Say so and carry on rather than refusing
            // to start over a convenience.
            let alert = NSAlert()
            alert.messageText = Strings.t("install.failed",
                default: "Could not move Hammerdeck to Applications")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }

        stripQuarantine(at: target)
        AppRelaunch.restart(at: target.path, thenExit: true)
        return true
    }

    /// Clear `com.apple.quarantine` from the bundle and everything inside it.
    ///
    /// Through `quarantinePropertiesKey` rather than shelling out to `xattr`: the
    /// seam's rule is that a subprocess whose output or status we consume rides
    /// `runProcessCore`, and a spawn added here would owe that roster an entry for
    /// something Foundation already does synchronously.
    ///
    /// Recursive because the flag sits on files INSIDE the bundle too, and one
    /// quarantined executable is enough to translocate the whole thing.
    private static func stripQuarantine(at url: URL) {
        func clear(_ target: URL) {
            var target = target
            var values = URLResourceValues()
            values.quarantineProperties = nil
            do { try target.setResourceValues(values) } catch {
                NSLog("[hammerdeck] could not clear quarantine on \(target.path): \(error)")
            }
        }
        clear(url)
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.quarantinePropertiesKey]) else { return }
        for case let child as URL in walker {
            if let v = try? child.resourceValues(forKeys: [.quarantinePropertiesKey]),
               v.quarantineProperties != nil {
                clear(child)
            }
        }
    }

    // MARK: - The panel

    private enum Choice { case move, decline }

    /// A modal window rather than an NSAlert: the whole point of the design is the
    /// familiar icon-arrow-folder picture, which an alert cannot draw.
    private static func runPanel() -> Choice {
        var choice = Choice.decline
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.level = .modalPanel

        let view = MovePanel(
            onMove: { choice = .move; NSApp.stopModal() },
            onDecline: { choice = .decline; NSApp.stopModal() })
        window.contentView = NSHostingView(rootView: view)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return choice
    }
}

/// Icon, arrow, Applications folder. The icon can be DRAGGED onto the folder, or
/// the button pressed -- both run the same move, because in this window we are the
/// ones doing the moving either way. The drag is here because it is the gesture
/// people have learned from every DMG, not because it does anything the button
/// does not.
private struct MovePanel: View {
    let onMove: () -> Void
    let onDecline: () -> Void

    @State private var drag: CGSize = .zero
    @State private var overTarget = false

    private let iconSide: CGFloat = 76
    private let gap: CGFloat = 96

    var body: some View {
        VStack(spacing: 18) {
            Text(Strings.t("install.title", default: "Move Hammerdeck to Applications?"))
                .font(.system(size: 15, weight: .semibold))

            Text(Strings.t("install.body",
                default: "Hammerdeck is running from outside your Applications folder. macOS restricts apps launched from there, and Hammerdeck will not be able to install its own updates.\n\nDrag it across, or press the button."))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 22)

            HStack(spacing: gap) {
                appIcon
                folderTile
            }
            .padding(.vertical, 4)

            HStack(spacing: 10) {
                Button(Strings.t("install.decline", default: "Not Now")) { onDecline() }
                Button(Strings.t("install.move", default: "Move to Applications")) { onMove() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 22)
        .frame(width: 460, height: 320)
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .frame(width: iconSide, height: iconSide)
            .offset(drag)
            .zIndex(1)
            .gesture(
                DragGesture(coordinateSpace: .local)
                    .onChanged { v in
                        drag = v.translation
                        // The folder sits one gap to the right; treat the second
                        // half of that run as "over it" so the drop is forgiving.
                        overTarget = v.translation.width > (gap + iconSide) / 2
                    }
                    .onEnded { _ in
                        if overTarget { onMove() } else {
                            withAnimation(.spring(response: 0.3)) { drag = .zero }
                            overTarget = false
                        }
                    })
    }

    private var folderTile: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: iconSide - 8, height: iconSide - 8)
                .foregroundStyle(overTarget ? Color.accentColor : Color.secondary)
            Text(Strings.t("install.applications", default: "Applications"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(overTarget ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: overTarget ? 2 : 1, dash: [5, 4])))
    }
}
