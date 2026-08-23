// Native.swift split: this file is one domain slice of the `Native` seam
// (see Native.swift for the class, shared state, and installBindings).
// Out-of-process execution -- the shared subprocess runner every caller rides,
// and the `exec` capability's Lua-facing `run_process`.

import AppKit
import CLua

/// One child stream (stdout or stderr): thread-safe accumulation behind a lock,
/// plus the single-claim latch that decides who owns the matching `group.leave()`.
///
/// Swift 6 forbids mutating a captured `var` across a @Sendable boundary (the
/// readabilityHandler and terminationHandler both run off-thread), so the bytes
/// live here. `@unchecked Sendable` because the lock, not the compiler, proves it.
private final class ProcessStream: @unchecked Sendable {
    /// Byte ceiling. A child that prints without bound must not grow the host's
    /// heap without bound. `Int.max` is the uncapped case (the JXA reader, whose
    /// payload is a tab list the caller must receive whole).
    let cap: Int
    private let lock = NSLock()
    private var data = Data()
    private var settled = false
    private var truncated = false

    init(cap: Int) { self.cap = cap }

    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        let room = cap - data.count
        if room <= 0 { truncated = true; return }
        if d.count <= room {
            data.append(d)
        } else {
            data.append(d.prefix(room))
            truncated = true
        }
    }

    /// Claim this stream's drained-to-EOF obligation. Returns true for exactly
    /// ONE caller, ever -- whoever gets it owns the matching `group.leave()`.
    /// Two racers exist by design: the readabilityHandler's EOF callback, and the
    /// post-exit fallback that covers the case where that callback never comes.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if settled { return false }
        settled = true
        return true
    }

    func result() -> (bytes: Data, truncated: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (data, truncated)
    }

    /// Read whatever is already buffered on `fd` and stop at EAGAIN -- never wait
    /// for the write end to close. Only correct where the caller knows no more
    /// bytes can arrive (the post-exit fallback); see the note at its call site
    /// for why waiting there hangs on an orphaned grandchild.
    ///
    /// Works on a `dup`, never on the caller's fd. O_NONBLOCK is a property of
    /// the open file description, so setting it on the original would change the
    /// mode under anyone else holding it -- and cancelling a dispatch read source
    /// (`readabilityHandler = nil`) does not synchronously prevent an already
    /// dispatched block from running. `-[NSFileHandle availableData]` RAISES on a
    /// read error, which is an uncatchable crash in Swift, so that race must not
    /// be left available. The dup also means the flag dies with the close.
    func drainWithoutBlocking(fd: Int32) {
        let copy = dup(fd)
        guard copy != -1 else { return }
        defer { close(copy) }
        let flags = fcntl(copy, F_GETFL)
        guard flags != -1, fcntl(copy, F_SETFL, flags | O_NONBLOCK) != -1 else { return }
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { read(copy, $0.baseAddress, $0.count) }
            if n > 0 {
                append(Data(buf[0..<n]))
            } else if n == 0 {
                return                                  // EOF
            } else if errno == EINTR {
                continue                                // a signal, not the end
            } else {
                return                                  // EAGAIN, or a dead fd
            }
        }
    }
}

/// The child's exit status, written off-thread by the termination handler and
/// read on the notify. Same `@unchecked Sendable`-behind-a-lock reason as above.
///
/// `hasExited` is what makes the terminator safe to hand out: a signal aimed at
/// a pid whose process is gone lands on whatever unrelated process has since
/// inherited the number.
private final class ProcessStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32 = -1
    private var done = false

    /// A child KILLED by signal N is reported as -N, so it can be told apart from
    /// one that chose to `exit N`. Without the sign, a watchdog timeout and a
    /// scope teardown both surface as plain 15 -- the same number `exit 15` gives
    /// -- and a caller has no way to know its command was cut short rather than
    /// having failed on its own terms. Foundation puts the signal number in
    /// `terminationStatus` and the distinction only in `terminationReason`.
    func set(_ s: Int32, signalled: Bool) {
        lock.lock()
        value = signalled ? -s : s
        done = true
        lock.unlock()
    }
    func get() -> Int32 { lock.lock(); defer { lock.unlock() }; return value }
    func hasExited() -> Bool { lock.lock(); defer { lock.unlock() }; return done }
}

/// Keeps the child's pipes ALIVE until the reads are finished.
///
/// THE ROOT CAUSE of the dropped-callback bug (2026-07-25), and it is ownership,
/// not a Foundation defect. With nothing holding a strong reference to the
/// `Pipe`, `Process` self-retains only while the child runs, so at termination it
/// deallocates, releasing standardOutput -> Pipe -> FileHandle -> `close(readFD)`.
/// That closes the read end while the dispatch readability source is still racing
/// to deliver its final empty-data (EOF) callback -- so on a child whose last
/// write and exit land within a millisecond, EOF is simply never delivered, the
/// stream obligation never completes, and the pinned Lua callback is dropped
/// forever.
///
/// Measured on this machine, same harness, `osascript` child, 150 runs each:
/// without a retain 69 hangs; holding the pipes to completion, 0. The failure is
/// not rare or exotic -- it was roughly one call in three.
///
/// `@unchecked Sendable` because `Pipe` is not Sendable and this only ever hands
/// it back on the completion path; the box is immutable after init.
private final class ProcessPipes: @unchecked Sendable {
    let out: Pipe, err: Pipe
    init(out: Pipe, err: Pipe) { self.out = out; self.err = err }
}

extension Native {
    // MARK: - The shared subprocess runner

    /// Launch `executable` with `args` out of process; deliver
    /// `(status, stdout, stderr)` exactly once. A `nil` status means the launch
    /// itself failed and no child ever existed -- and that one path completes
    /// SYNCHRONOUSLY, re-entrantly, before this function returns; every other
    /// path lands on the main queue. A NEGATIVE status is a signal number: the
    /// child was killed (the timeout below, or the terminator), not an exit code
    /// it chose.
    ///
    /// Async by construction: a subprocess cannot hang the host at all, which is
    /// why this shape is preferred over anything synchronous and cross-process
    /// (see the AppleScript rule in Native+AppleScript.swift).
    ///
    /// Completion joins THREE obligations -- stdout EOF, stderr EOF, and process
    /// exit -- so nothing ever blocks waiting on one of them. Draining both pipes
    /// is not optional: an unread stream fills its ~64KB kernel buffer and wedges
    /// the child in `write()`, which is the deadlock this shape exists to avoid.
    /// A watchdog SIGTERMs a still-RUNNING hung child (an unanswered TCC prompt, a
    /// beachball) so the reads hit EOF and completion still fires.
    ///
    /// Exactly one completion per call: the throw path returns before `notify` is
    /// registered.
    ///
    /// Returns a TERMINATOR the caller can hand to `armOneShot`, so a scope
    /// teardown stops the child rather than only dropping its callback. It is a
    /// no-op once the child has exited -- never signal a pid that may have been
    /// recycled -- and nil when the launch failed and no child ever existed.
    @discardableResult
    func runProcessCore(executable: String,
                        args: [String],
                        timeout: TimeInterval,
                        label: String,
                        stdoutCap: Int = Int.max,
                        stderrCap: Int = Int.max,
                        completion: @escaping @Sendable (Int32?, Data, Data) -> Void)
    -> (@Sendable () -> Void)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        // Strong reference held past this function's return -- the whole fix.
        let pipes = ProcessPipes(out: out, err: err)

        let outSink = ProcessStream(cap: stdoutCap)
        let errSink = ProcessStream(cap: stderrCap)
        let status = ProcessStatus()
        let group = DispatchGroup()

        // One drain per stream: obligations 1 and 2.
        for (pipe, sink) in [(out, outSink), (err, errSink)] {
            group.enter()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty {
                    h.readabilityHandler = nil
                    if sink.claim() { group.leave() }
                } else {
                    sink.append(d)
                }
            }
        }

        group.enter()   // obligation 3: process exit (Process arrives as the param, never captured)
        p.terminationHandler = { proc in
            status.set(proc.terminationStatus, signalled: proc.terminationReason == .uncaughtSignal)
            group.leave()

            // BELT-AND-BRACES, not the fix. The fix is holding `pipes` alive
            // (see ProcessPipes) -- with the read end kept open, EOF is delivered
            // every time (0 losses in 150 runs, against 69 without it).
            //
            // This remains because a lost EOF costs a permanently dropped Lua
            // callback, and the child's exit is proof no more data can arrive:
            // after a grace period for the real EOF, claim each outstanding
            // obligation so the group can never stay open. Whichever path claims
            // first wins; the other becomes a no-op.
            //
            // The grace matters -- claiming immediately would routinely beat the
            // legitimate EOF and make TWO readers on one live fd the common case.
            // It reads through the RETAINED handle's fd, valid only because
            // `pipes` is alive in this closure: an earlier version captured
            // `fileDescriptor` as an Int32 and read from it 0.25s later, which
            // measured as closed in 100% of firings -- a use-after-close that
            // could have read, and advanced the offset of, whatever unrelated
            // file had since been handed that fd number.
            //
            // The drain is NON-BLOCKING, and that is load-bearing rather than
            // tidy. A pipe's read end reports EOF only when the last WRITE end
            // closes, and a grandchild inherits the child's -- so `sh -c 'sleep
            // 20 &'` exits instantly while its orphan holds stderr, and a
            // blocking read here waits on the orphan: the group never empties,
            // the completion never fires, the pinned Lua callback is lost, and
            // the watchdog below then signals a pid that died 20 seconds ago.
            // Nothing is given up by not waiting -- the child's exit is proof no
            // more of ITS bytes can arrive, so draining to EAGAIN collects
            // everything a lost EOF could have stranded.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                for (name, pipe, sink) in [("stdout", pipes.out, outSink),
                                           ("stderr", pipes.err, errSink)] {
                    guard sink.claim() else { continue }   // real EOF got there first
                    let fh = pipe.fileHandleForReading
                    // Sole reader from here: the handler is retired BEFORE draining,
                    // so the two cannot split the byte stream between them.
                    fh.readabilityHandler = nil
                    sink.drainWithoutBlocking(fd: fh.fileDescriptor)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            Native.shared.seamLogThrottled(
                                "proc-lost-eof-\(label)-\(name)",
                                "\(label): \(name) EOF never arrived after child exit; completed the "
                                + "read from the termination fallback. Expected to be silent -- if this "
                                + "appears, the pipe-retention fix in runProcessCore is not holding.")
                        }
                    }
                    group.leave()
                }
            }
        }

        do { try p.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            p.terminationHandler = nil
            // Balance all three enters (an entered group traps on dealloc). The
            // claims keep this exactly-once against a handler already in flight.
            if outSink.claim() { group.leave() }
            if errSink.claim() { group.leave() }
            group.leave()
            completion(nil, Data(), Data())
            return nil                     // notify never registered -> exactly-once holds
        }

        // Watchdog: SIGTERM a STILL-RUNNING hung child so the reads hit EOF and
        // completion still fires. It covers only that case -- a child that never
        // exits. It cannot rescue a child that already exited, because then there
        // is nothing left to close the pipe; that case is the pipe retention plus
        // the termination fallback above. Addresses the child by PID (Int32 is
        // Sendable; Process is not) and runs on .main, matching the notify below.
        //
        // Both are cancelled by notify and both re-check hasExited() before
        // signalling. Either alone would leave a window: cancellation races a
        // deadline that has already been dequeued, and the check races an exit by
        // microseconds. Signalling a long-dead pid is not a harmless ESRCH --
        // pids are recycled, and it would land on whatever inherited the number.
        //
        // SIGTERM is catchable, so it is not on its own a bound: `trap '' TERM`
        // would leave the child running and the completion outstanding forever.
        // SIGKILL a few seconds later is the ceiling on the DIRECT CHILD.
        //
        // It is not a ceiling on what that child spawned. Process does not put
        // the child in its own group, so these signal one pid: a command that
        // backgrounds work (`rsync ... &`) leaves the grandchild running after
        // both the timeout and a scope teardown. That shape is not exotic -- the
        // orphan test below is built on it -- so it is a documented limit of the
        // tier, not an oversight. Closing it means spawning into a process group
        // and signalling -pgid, which Process cannot express.
        let pid = p.processIdentifier
        let watchdog = DispatchWorkItem { if !status.hasExited() { kill(pid, SIGTERM) } }
        let hardStop = DispatchWorkItem { if !status.hasExited() { kill(pid, SIGKILL) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: watchdog)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout + 3, execute: hardStop)

        group.notify(queue: .main) {
            // THE RETAIN. Holding `pipes` across the whole run is what keeps the
            // read ends open until the readers are finished. `withExtendedLifetime`
            // (not a bare mention) so no optimizer is free to release it early.
            withExtendedLifetime(pipes) {}
            watchdog.cancel()
            hardStop.cancel()
            let o = outSink.result(), e = errSink.result()
            if o.truncated || e.truncated {
                // A silently short string would be a lie the caller cannot detect,
                // so the truncation goes to the daily log even though the callback
                // signature stays (status, stdout, stderr).
                // Throttled: runJXA sits on tab_switcher's refresh poll, so a
                // chatty osascript past the stderr cap would write a daily-log
                // line on every tick -- for bytes that caller discards anyway.
                MainActor.assumeIsolated {
                    Native.shared.seamLogThrottled(
                        "proc-truncated-\(label)",
                        "\(label): output hit the capture ceiling and was truncated "
                        + "(stdout \(o.bytes.count)B\(o.truncated ? ", capped" : ""), "
                        + "stderr \(e.bytes.count)B\(e.truncated ? ", capped" : ""))")
                }
            }
            completion(status.get(), o.bytes, e.bytes)
        }

        // The check-then-signal window is microseconds wide, against pid reuse
        // that needs a full wraparound -- a different hazard from the watchdog's
        // "signal a pid that died a minute ago", which is what hasExited() and
        // the cancels above exist to rule out.
        return {
            guard !status.hasExited() else { return }
            kill(pid, SIGTERM)
        }
    }

    // MARK: - The `exec` capability

    /// Ceiling on a `run_process` child. Long enough for a real build or network
    /// command, short enough that a wedged child is reaped rather than leaked.
    static let runProcessTimeoutSeconds: TimeInterval = 60

    /// Per-stream capture ceiling for `run_process`. Output beyond this is dropped
    /// and the truncation is logged; a feature that needs more should have its
    /// command write to a file.
    static let runProcessOutputCap = 1 << 20   // 1 MiB

    /// `run_process(path, args, cb)` -> resource id. The one native call behind
    /// the `exec` capability; `cb(status, stdout, stderr)`.
    ///
    /// An ARGV ARRAY, never a shell string: there is no shell in the loop, so a
    /// quoting bug cannot become an injection bug, and no `~`, `*`, `|` or `$VAR`
    /// is interpreted. An ABSOLUTE path, so `$PATH` cannot decide what runs.
    ///
    /// Every launch is logged before it happens -- the daily log is the whole
    /// point of routing this through the seam rather than leaving features to call
    /// `os.execute`, which the embedded state no longer offers (see LuaState.init).
    ///
    /// Returns a resource id: the call is a cancelable one-shot, and the cancel
    /// TERMINATES the child rather than only dropping the callback. `exec` is the
    /// tier where that matters most -- an abandoned `rsync` or `git push` goes on
    /// changing the machine after the user turned the feature off.
    func runProcess(_ L: OpaquePointer?) -> Int32 {
        guard let path = LuaState.string(L, 1), path.hasPrefix("/") else {
            return luaError(L, "run_process: an ABSOLUTE executable path is required "
                             + "(e.g. \"/usr/bin/git\", not \"git\")")
        }
        // A wrong-shaped container must RAISE, not silently run the program with no
        // arguments: `ctx.run("/usr/bin/git", "status", cb)` is the mistake someone
        // reaching for a shell actually makes, and it would otherwise run bare
        // `git`. Only an absent/nil second argument means "no arguments".
        var args: [String] = []
        let argType = lua_type(L, 2)
        if argType != LUA_TNIL && argType != LUA_TNONE {
            guard let raw = LuaState.any(L, 2) as? [Any] else {
                return luaError(L, "run_process: args must be an ARRAY of strings, "
                                 + "e.g. { \"status\", \"--porcelain\" }")
            }
            for a in raw {
                guard let s = a as? String else {
                    return luaError(L, "run_process: every argument must be a string")
                }
                args.append(s)
            }
        }
        let ref = lua.makeRef(at: 3)
        let id = allocOneShot()
        // Full argv, because "which command actually ran" is the entire reason this
        // tier goes through the seam. It persists for the log's retention window,
        // so the authoring guide tells extension authors not to pass secrets as
        // arguments.
        seamLog("run: \(path)\(args.isEmpty ? "" : " " + args.joined(separator: " "))")
        let terminate = runProcessCore(executable: path, args: args,
                                       timeout: Native.runProcessTimeoutSeconds,
                                       label: "run",
                                       stdoutCap: Native.runProcessOutputCap,
                                       stderrCap: Native.runProcessOutputCap) { status, out, err in
            Native.fireOneShot(id, ref) { L in
                if let status { lua_pushinteger(L, lua_Integer(status)) } else { lua_pushnil(L) }
                // RAW BYTES. Lua strings are 8-bit clean, and command output is
                // routinely not: `find -print0` / `git -z` are NUL-separated, and
                // lua_pushstring stops at the first one -- a silently short result
                // with nothing to distinguish it from a short command.
                Native.pushBytes(L, out)
                Native.pushBytes(L, err)
                return 3
            }
        }
        armOneShot(id, ref) { terminate?() }
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    /// Push `data` as a Lua string without a NUL-terminator round trip.
    nonisolated static func pushBytes(_ L: OpaquePointer, _ data: Data) {
        data.withUnsafeBytes { raw in
            lua_pushlstring(L, raw.baseAddress?.assumingMemoryBound(to: CChar.self), raw.count)
        }
    }
}
