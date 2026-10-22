// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Darwin
import Foundation
import Libmpv
import Synchronization

public enum MPVError: Error, Sendable, Equatable, CustomStringConvertible {
    case createFailed
    case initializeFailed(Int32)
    case shutDown
    case command(Int32)
    case invalidOptions(LoadFileOptionsError)

    public var description: String {
        switch self {
        case .createFailed: return "mpv_create failed"
        case .initializeFailed(let e): return "mpv_initialize failed: \(MPVClient.errorString(e))"
        case .shutDown: return "mpv client is shut down"
        case .command(let e): return "mpv command failed: \(MPVClient.errorString(e))"
        case .invalidOptions(let e): return "invalid loadfile options: \(e)"
        }
    }
}

/// The reply to an async command.
public struct MPVReply: Sendable, Equatable {
    public var error: Int32
    public var result: MPVNode
    public var ok: Bool { error >= 0 }
}

/// Result of setting one global option before `mpv_initialize` (E1 records these).
public struct MPVOptionResult: Sendable, Codable, Equatable {
    public var name: String
    public var value: String
    public var error: Int32
    public var ok: Bool { error >= 0 }
}

/// Owns one `mpv_handle` (DESIGN §5.2). Commands go through `mpv_command_node_async` only; events are converted
/// to Sendable values on a dedicated thread (`sudamp.mpv.events`) blocking in `mpv_wait_event(h, -1)` and are
/// delivered through `events`, an optional handler, and the `snapshot` of observed properties.
///
/// Shutdown order (DESIGN §5.2 Lifecycle): the caller stops the audio engine first; `shutdown()` then sets the
/// stopping flag → `mpv_wakeup` → joins the event thread → `mpv_terminate_destroy`.
/// Sendable without escape hatches: every stored property is immutable and Sendable. libmpv's client API is
/// thread-safe for one handle (client.h, "Thread safety"); its one extra rule, a single `mpv_wait_event` caller,
/// is kept by the event thread, and HandleGuard stops calls racing `mpv_terminate_destroy`.
public final class MPVClient: Sendable {
    /// Every global option set before `mpv_initialize`, with mpv's verdict.
    public let optionResults: [MPVOptionResult]
    /// Converted events. Buffers the newest 4096 if nobody is consuming.
    public let events: AsyncStream<MPVEvent>

    private let handle: HandleGuard
    private let pump: EventPump
    private let nextRequestID = Atomic<UInt64>(1)
    private let shutdownState = Mutex(false)
    private let log = Log.logger("mpv")

    /// - Parameters:
    ///   - options: the global option block (DESIGN §5.2 defaults, merged with tool overrides).
    ///   - logLevel: `mpv_request_log_messages` level ("warn" keeps errors for reports; tools use "v"/"debug").
    ///   - eventHandler: called on the event thread for every event, before `events` yields it.
    public init(options: [MPVOption] = MPVOptions.defaults, logLevel: String = "warn",
                eventHandler: (@Sendable (MPVEvent) -> Void)? = nil) throws(MPVError) {
        // libmpv requires the C numeric locale, and no longer ignores SIGPIPE for the host (DESIGN §5.2).
        setlocale(LC_NUMERIC, "C")
        signal(SIGPIPE, SIG_IGN)
        guard let raw = mpv_create() else { throw .createFailed }
        var results: [MPVOptionResult] = []
        for option in options {
            let r = mpv_set_option_string(raw, option.name, option.value)
            results.append(MPVOptionResult(name: option.name, value: option.value, error: r))
        }
        mpv_request_log_messages(raw, logLevel)
        let status = mpv_initialize(raw)
        guard status >= 0 else {
            mpv_terminate_destroy(raw)
            throw .initializeFailed(status)
        }
        for (i, name) in MPVOptions.observedProperties.enumerated() {
            mpv_observe_property(raw, UInt64(i + 1), name, MPV_FORMAT_NODE)
        }
        optionResults = results
        handle = HandleGuard(raw)
        let (stream, continuation) = AsyncStream.makeStream(of: MPVEvent.self, bufferingPolicy: .bufferingNewest(4096))
        events = stream
        pump = EventPump(handle: handle, continuation: continuation, handler: eventHandler)
        for r in results where !r.ok {
            log.error("mpv option \(r.name, privacy: .public)=\(r.value, privacy: .public) rejected: \(MPVClient.errorString(r.error), privacy: .public)")
        }
        let pump = self.pump
        let thread = Thread { pump.run() }
        thread.name = "sudamp.mpv.events"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit { shutdown() }

    /// Replaces the event handler (called on the event thread).
    public func setEventHandler(_ handler: (@Sendable (MPVEvent) -> Void)?) { pump.setHandler(handler) }

    /// Latest observed property values.
    public var snapshot: PlaybackSnapshot { pump.snapshot }

    /// The newest error/fatal log lines and failed end-file events (at most 50), for reports and error UI.
    public var recentErrors: [String] { pump.recentErrors }

    public var isShutDown: Bool { shutdownState.withLock { $0 } }

    // MARK: Async commands

    /// Issues a command without waiting. Returns the request id (its reply arrives as `.commandReply`).
    @discardableResult
    public func send(_ args: [String]) throws(MPVError) -> UInt64 {
        try send(node: .array(args.map(MPVNode.string)))
    }

    @discardableResult
    public func send(node: MPVNode) throws(MPVError) -> UInt64 {
        let id = nextRequestID.wrappingAdd(1, ordering: .relaxed).oldValue
        let status: Int32? = handle.with { h in node.withCNode { mpv_command_node_async(h, id, $0) } }
        guard let status else { throw .shutDown }
        guard status >= 0 else { throw .command(status) }
        return id
    }

    /// Issues a command and awaits its reply.
    public func request(_ args: [String]) async -> MPVReply {
        await request(node: .array(args.map(MPVNode.string)))
    }

    public func request(node: MPVNode) async -> MPVReply {
        let id = nextRequestID.wrappingAdd(1, ordering: .relaxed).oldValue
        return await withCheckedContinuation { (continuation: CheckedContinuation<MPVReply, Never>) in
            pump.register(id, continuation)
            let status: Int32? = handle.with { h in node.withCNode { mpv_command_node_async(h, id, $0) } }
            if (status ?? -1) < 0 {
                pump.resolve(id, MPVReply(error: status ?? MPV_ERROR_UNINITIALIZED.rawValue, result: .none))
            }
        }
    }

    // MARK: Transport conveniences (all async API)

    public enum LoadMode: String, Sendable { case replace, append, appendPlay = "append-play" }

    /// `loadfile <url> <mode> -1 <options>`.
    @discardableResult
    public func loadfile(_ url: String, mode: LoadMode = .replace, options: LoadFileOptions = LoadFileOptions())
        throws(MPVError) -> UInt64 {
        try send(node: Self.loadfileNode(url, mode: mode, options: options))
    }

    public func loadfileAndWait(_ url: String, mode: LoadMode = .replace,
                                options: LoadFileOptions = LoadFileOptions()) async throws(MPVError) -> MPVReply {
        let node = try Self.loadfileNode(url, mode: mode, options: options)
        return await request(node: node)
    }

    static func loadfileNode(_ url: String, mode: LoadMode, options: LoadFileOptions) throws(MPVError) -> MPVNode {
        let map: [String: String]
        do { map = try options.optionMap() } catch { throw .invalidOptions(error) }
        var node: [String: MPVNode] = [
            "name": .string("loadfile"), "url": .string(url), "flags": .string(mode.rawValue), "index": .int(-1),
        ]
        if !map.isEmpty { node["options"] = .map(map.mapValues(MPVNode.string)) }
        return .map(node)
    }

    @discardableResult
    public func setPause(_ paused: Bool) throws(MPVError) -> UInt64 { try send(["set", "pause", paused ? "yes" : "no"]) }

    @discardableResult
    public func seek(to seconds: Double) throws(MPVError) -> UInt64 { try send(["seek", String(seconds), "absolute"]) }

    @discardableResult
    public func stop() throws(MPVError) -> UInt64 { try send(["stop"]) }

    @discardableResult
    public func setProperty(_ name: String, _ value: String) throws(MPVError) -> UInt64 { try send(["set", name, value]) }

    // MARK: Typed getters (synchronous; microseconds with the pull AO)

    public func getString(_ name: String) -> String? {
        handle.with { h -> String? in
            guard let p = mpv_get_property_string(h, name) else { return nil }
            defer { mpv_free(p) }
            return String(cString: p)
        } ?? nil
    }

    public func getDouble(_ name: String) -> Double? {
        handle.with { h -> Double? in
            var v: Double = 0
            return mpv_get_property(h, name, MPV_FORMAT_DOUBLE, &v) >= 0 ? v : nil
        } ?? nil
    }

    public func getInt(_ name: String) -> Int64? {
        handle.with { h -> Int64? in
            var v: Int64 = 0
            return mpv_get_property(h, name, MPV_FORMAT_INT64, &v) >= 0 ? v : nil
        } ?? nil
    }

    public func getFlag(_ name: String) -> Bool? {
        handle.with { h -> Bool? in
            var v: Int32 = 0
            return mpv_get_property(h, name, MPV_FORMAT_FLAG, &v) >= 0 ? v != 0 : nil
        } ?? nil
    }

    public func getNode(_ name: String) -> MPVNode? {
        handle.with { h -> MPVNode? in
            var node = mpv_node()
            guard mpv_get_property(h, name, MPV_FORMAT_NODE, &node) >= 0 else { return nil }
            defer { mpv_free_node_contents(&node) }
            return MPVNode(node)
        } ?? nil
    }

    public var mpvVersion: String? { getString("mpv-version") }
    public var audioOutParams: AudioParams? { getNode("audio-out-params").flatMap(AudioParams.init(node:)) }
    public var audioParams: AudioParams? { getNode("audio-params").flatMap(AudioParams.init(node:)) }

    /// Runtime guard values right now (DESIGN §5.3).
    public func guards() -> EngineGuards {
        EngineGuards(mpvVersion: mpvVersion, aoInitCount: PullAO.initCount, aoErrorCount: PullAO.errorCount,
                     audioOutParams: audioOutParams)
    }

    // MARK: Shutdown

    /// Idempotent. Stop the audio engine before calling (DESIGN §5.2 Lifecycle).
    public func shutdown() {
        let already = shutdownState.withLock { done -> Bool in
            defer { done = true }
            return done
        }
        if already {
            pump.waitUntilFinished()
            return
        }
        pump.requestStop()
        _ = handle.with { mpv_wakeup($0) }
        pump.waitUntilFinished()
        handle.destroy()
    }

    public static func errorString(_ code: Int32) -> String { String(cString: mpv_error_string(code)) }
}

/// Guards the raw handle so no API call races `mpv_terminate_destroy`.
// The handle itself is thread-safe per libmpv.
// SAFETY: `destroyed` is only written under the write lock and only read under a read lock.
final class HandleGuard: @unchecked Sendable {
    private let raw: OpaquePointer
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>
    private var destroyed = false

    init(_ raw: OpaquePointer) {
        self.raw = raw
        lock = .allocate(capacity: 1)
        pthread_rwlock_init(lock, nil)
    }

    deinit {
        pthread_rwlock_destroy(lock)
        lock.deallocate()
    }

    /// Runs `body` with the live handle, or returns nil once destroyed.
    func with<R>(_ body: (OpaquePointer) -> R) -> R? {
        pthread_rwlock_rdlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return destroyed ? nil : body(raw)
    }

    /// For the event thread only: valid until `destroy()`, which runs after that thread is joined.
    var eventThreadHandle: OpaquePointer { raw }

    func destroy() {
        pthread_rwlock_wrlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        guard !destroyed else { return }
        mpv_terminate_destroy(raw)
        destroyed = true
    }
}

/// The event thread's state: converts events, keeps the snapshot and resolves awaited replies.
/// `run()` executes on exactly one thread; everything it shares with other threads is in a Mutex or Atomic.
final class EventPump: Sendable {
    private let handle: HandleGuard
    private let continuation: AsyncStream<MPVEvent>.Continuation
    /// Boxed: on Swift 6.4, `withLock { $0 }` returning an optional closure added two stack frames per call, so
    /// the 512 KB event thread overflowed after ~100 s of playback (SIGBUS, found in M1). A class box keeps it flat.
    private let handler: Mutex<HandlerBox?>
    private let pending = Mutex<[UInt64: CheckedContinuation<MPVReply, Never>]>([:])
    private let state = Mutex(PlaybackSnapshot())
    private let stopping = Atomic<Bool>(false)
    private let finished = Mutex(false)
    private let finishedSignal = DispatchSemaphore(value: 0)
    private let errors = Mutex<[String]>([])

    init(handle: HandleGuard, continuation: AsyncStream<MPVEvent>.Continuation,
         handler: (@Sendable (MPVEvent) -> Void)?) {
        self.handle = handle
        self.continuation = continuation
        self.handler = Mutex(handler.map(HandlerBox.init))
    }

    var snapshot: PlaybackSnapshot { state.withLock { $0 } }

    var recentErrors: [String] { errors.withLock { $0 } }

    private func noteError(_ message: String) {
        errors.withLock { list in
            list.append(message)
            if list.count > 50 { list.removeFirst(list.count - 50) }
        }
    }

    func setHandler(_ h: (@Sendable (MPVEvent) -> Void)?) { handler.withLock { $0 = h.map(HandlerBox.init) } }

    func register(_ id: UInt64, _ c: CheckedContinuation<MPVReply, Never>) {
        let accepted = pending.withLock { p -> Bool in
            guard !finished.withLock({ $0 }) else { return false }
            p[id] = c
            return true
        }
        if !accepted { c.resume(returning: MPVReply(error: MPV_ERROR_UNINITIALIZED.rawValue, result: .none)) }
    }

    func resolve(_ id: UInt64, _ reply: MPVReply) {
        pending.withLock { $0.removeValue(forKey: id) }?.resume(returning: reply)
    }

    func requestStop() { stopping.store(true, ordering: .releasing) }

    /// Joins the event thread (idempotent).
    func waitUntilFinished() {
        if finished.withLock({ $0 }) { return }
        finishedSignal.wait()
        finishedSignal.signal() // let any other waiter through
    }

    func run() {
        let h = handle.eventThreadHandle
        while !stopping.load(ordering: .acquiring) {
            guard let raw = mpv_wait_event(h, -1) else { continue }
            let id = raw.pointee.event_id
            if id == MPV_EVENT_NONE { continue }
            let event = MPVEvent(raw.pointee)
            deliver(event)
            if id == MPV_EVENT_SHUTDOWN { break }
        }
        let leftovers = pending.withLock { p -> [CheckedContinuation<MPVReply, Never>] in
            finished.withLock { $0 = true }
            defer { p.removeAll() }
            return Array(p.values)
        }
        for c in leftovers { c.resume(returning: MPVReply(error: MPV_ERROR_UNINITIALIZED.rawValue, result: .none)) }
        continuation.finish()
        finishedSignal.signal()
    }

    private func deliver(_ event: MPVEvent) {
        switch event {
        case .propertyChange(let name, let value):
            state.withLock { $0.apply(property: name, value: value) }
        case .fileLoaded:
            state.withLock { $0.filesLoaded += 1 }
        case .playbackRestart:
            state.withLock { $0.playbackRestarts += 1 }
        case .endFile(let e):
            state.withLock { $0.lastEndFile = e }
            if e.reason == .error { noteError("end-file: \(e.errorDescription ?? String(e.error))") }
        case .log(let m) where m.level == "error" || m.level == "fatal":
            noteError("\(m.prefix): \(m.text)")
        case .commandReply(let id, let error, let result):
            resolve(id, MPVReply(error: error, result: result))
        default:
            break
        }
        handler.withLock { $0 }?.call(event)
        continuation.yield(event)
    }
}

/// Holds the event handler closure by reference (see `EventPump.handler`).
final class HandlerBox: Sendable {
    let call: @Sendable (MPVEvent) -> Void
    init(_ call: @escaping @Sendable (MPVEvent) -> Void) { self.call = call }
}

