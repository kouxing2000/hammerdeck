// Native.swift split: this file is one domain slice of the `Native`
// seam (see Native.swift for the class, shared state, and installBindings).
// Reliable cross-app activation via the private SkyLight SLPS front-process API.

import AppKit

extension Native {
    // MARK: - Reliable cross-app activation (SkyLight SLPS)
    //
    // NSRunningApplication.activate() is *cooperative* on macOS 14+: the system
    // honors "bring app B forward" only from the currently-active app (or one it
    // yields to). We are an .accessory app showing a .nonactivatingPanel, so we
    // are NEVER the active app -- which made focus_window / activate_app raise a
    // window inside its app yet intermittently fail to front the app itself
    // (it worked only when the target app already happened to be frontmost).
    // AltTab / yabai / the Hammerspoon #370 thread all converge on the SkyLight
    // SLPS front-process API, which is not gated by cooperative activation.
    // Resolved via dlsym (no private-framework link flag), and with a
    // hand-rolled PSN struct + dlsym'd GetProcessForPID so we reference no
    // deprecated Carbon symbols.

    /// Bring `pid`'s app frontmost and -- when `wid != 0` -- make that exact
    /// window key, bypassing cooperative activation. Returns false (so the caller
    /// can fall back) only if the private SLPS symbols can't be resolved.
    @discardableResult
    func activateFrontProcess(pid: pid_t, wid: CGWindowID = 0) -> Bool {
        guard let getPSN = SLPS.getProcessForPID, let setFront = SLPS.setFrontProcess else {
            return false
        }
        var psn = SLPSProcessSerial()
        guard getPSN(pid, &psn) == 0 else { return false }
        withUnsafeMutableBytes(of: &psn) { p in
            _ = setFront(p.baseAddress!, wid, SLPS.userGenerated)
        }
        if wid != 0, let post = SLPS.postEvent {
            makeKeyWindow(&psn, wid: wid, post: post)
        }
        return true
    }

    // The two-event SLPS dance that makes window `wid` the key window of its
    // process (ported faithfully from the Hammerspoon #370 / yabai recipe; the
    // magic byte offsets are an undocumented SLPS event record).
    private func makeKeyWindow(_ psn: inout SLPSProcessSerial, wid: CGWindowID,
                               post: SLPS.PostEventFn) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x08] = 0x01
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: wid) { src in
            for i in 0..<4 { bytes[0x3c + i] = src[i] }
        }
        for i in 0..<0x10 { bytes[0x20 + i] = 0xff }
        withUnsafeMutableBytes(of: &psn) { psnPtr in
            bytes.withUnsafeMutableBytes { _ = post(psnPtr.baseAddress!, $0.baseAddress!) }
            bytes[0x08] = 0x02
            bytes.withUnsafeMutableBytes { _ = post(psnPtr.baseAddress!, $0.baseAddress!) }
        }
    }
}

// A private ProcessSerialNumber stand-in: reimplemented so the SLPS plumbing
// touches no deprecated Carbon types (the real PSN struct is deprecated too).
private struct SLPSProcessSerial { var hi: UInt32 = 0; var lo: UInt32 = 0 }

// dlsym-resolved private SkyLight + Carbon entry points. Lazy statics -> resolved
// once, thread-safely. nil if a symbol ever disappears (callers fall back).
private enum SLPS {
    typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    typealias SetFrontFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, UInt32) -> Int32
    typealias PostEventFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32

    static let userGenerated: UInt32 = 0x200   // kCPSUserGenerated

    static let getProcessForPID: GetProcessForPIDFn? = sym("GetProcessForPID")
    static let setFrontProcess: SetFrontFn? = sym("_SLPSSetFrontProcessWithOptions")
    static let postEvent: PostEventFn? = sym("SLPSPostEventRecordTo")

    // The SLPS symbols live in SkyLight; GetProcessForPID lives in
    // ApplicationServices (and is `unavailable` to Swift, hence dlsym). dlopen
    // both so resolution never hinges on AppKit's framework load order, with
    // RTLD_DEFAULT (-2) as a final catch-all for anything already mapped. Read
    // once, never mutated -> the unchecked annotation is sound.
    nonisolated(unsafe) private static let handles: [UnsafeMutableRawPointer?] = [
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
        dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
        UnsafeMutableRawPointer(bitPattern: -2),
    ]

    private static func sym<T>(_ name: String) -> T? {
        for h in handles {
            if let h, let p = dlsym(h, name) { return unsafeBitCast(p, to: T.self) }
        }
        return nil
    }
}
