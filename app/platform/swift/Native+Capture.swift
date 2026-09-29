// The capture slice of the seam: a picture of one window, for a preview.
//
// Reading another app's pixels needs Screen Recording -- Accessibility cannot
// see them -- so everything here first asks whether that grant is in force, and
// never prompts on its own: a caller decides when the prompt is worth showing.
// macOS 14 is the floor (SCScreenshotManager); before it there is no preview.

import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

extension Native {
    /// Whether a window can be captured now. Never prompts. Also false after a
    /// fresh grant until Hammerdeck relaunches: macOS applies a Screen Recording
    /// grant to processes started after it.
    static var canCaptureWindows: Bool {
        guard #available(macOS 14.0, *) else { return false }
        return CGPreflightScreenCaptureAccess()
    }

    private static var askedForCapture = false

    /// Ask for Screen Recording, at most once per launch. macOS shows its prompt
    /// only the first time it is asked; after a denial the answer lives in System
    /// Settings, and asking again does nothing.
    static func requestWindowCapture() {
        guard #available(macOS 14.0, *), !askedForCapture else { return }
        askedForCapture = true
        shared.seamLog("capture: asking for Screen Recording (window previews)")
        _ = CGRequestScreenCaptureAccess()
    }

    /// One surface's captures: the list of shareable windows is fetched on the
    /// first capture and reused, since listing every window costs ~70 ms and one
    /// capture ~40 (measured). Make one per surface that shows previews and drop
    /// it with the surface, so the list never outlives the windows it names.
    @available(macOS 14.0, *)
    @MainActor
    final class WindowShots {
        private var windows: [SCWindow]?

        /// Window `wid`, `width` pixels wide at its own aspect; nil when it cannot
        /// be had (no grant, the window is gone, the capture failed).
        func image(of wid: CGWindowID, width: Int) async -> CGImage? {
            if windows == nil {
                do {
                    windows = try await SCShareableContent.excludingDesktopWindows(
                        false, onScreenWindowsOnly: false).windows
                } catch {
                    Native.shared.seamLogThrottled("capture.list", "capture: window list failed: \(error.localizedDescription)")
                    return nil
                }
            }
            guard let window = windows?.first(where: { $0.windowID == wid }) else { return nil }
            let cfg = SCStreamConfiguration()
            cfg.width = max(1, width)
            cfg.height = max(1, Int(CGFloat(width) * window.frame.height / max(1, window.frame.width)))
            cfg.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: window)
            // The completion-handler form: the async overload does not resolve to
            // a CGImage with this SDK.
            let result: Result<CGImage, Error> = await withCheckedContinuation { k in
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { image, error in
                    if let image { k.resume(returning: .success(image)) }
                    else { k.resume(returning: .failure(error ?? CocoaError(.featureUnsupported))) }
                }
            }
            switch result {
            case .success(let image): return image
            case .failure(let error):
                Native.shared.seamLogThrottled("capture.window", "capture: window \(wid) failed: \(error.localizedDescription)")
                return nil
            }
        }
    }
}
