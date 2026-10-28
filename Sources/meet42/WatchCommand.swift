// WatchCommand.swift — `meet42 watch`: event-driven (+ 1s backstop), input-only
// mic monitor.
//
// Detection is driven by CoreAudio property listeners, PLUS a 1s backstop
// re-scan (see MicWatcher.start) because macOS does not reliably notify when a
// process that is already in the list starts capturing the mic. The backstop
// emits only on the open↔close edge (not level-polling), so "prompt once per
// call" is preserved; the listeners still give sub-second latency in the common
// fresh-process case. Two listeners cooperate on one serial DispatchQueue:
//
//   1. kAudioHardwarePropertyProcessObjectList on kAudioObjectSystemObject:
//      fires whenever a process starts or stops audio I/O. In its callback
//      we keep per-process input listeners in sync (add for new, remove
//      bookkeeping for gone) and call recompute().
//
//   2. kAudioProcessPropertyIsRunningInput on each process object: fires the
//      instant a process opens or closes mic INPUT capture. Its callback calls
//      recompute().  We NEVER register on kAudioProcessPropertyIsRunning (any
//      I/O) or the device-wide kAudioDevicePropertyDeviceIsRunningSomewhere —
//      those output-inclusive flags are the exact bug being fixed.
//
// recompute() applies a two-gate filter to the current process list:
//   Gate 1 — kAudioProcessPropertyIsRunningInput == true (mic input held)
//   Gate 2 — kAudioProcessPropertyBundleID prefix-matches the call-app catalog
// A process passing both gates is a "call holder". recompute() emits only on
// the aggregate empty↔non-empty edge:
//
//   {"event":"call-open","callId":"us.zoom.xos-1696...","app":"Zoom","bundleId":"us.zoom.xos"}
//   {"event":"call-close","callId":"us.zoom.xos-1696..."}
//
// All stdout goes through one emit() function; nothing else writes to stdout.
// The process is kept alive via dispatchMain() — no while/sleep loop anywhere.

import CoreAudio
import Foundation
import Meet42Capture

enum WatchCommand {

    // MARK: - Catalog

    /// Canonical bundle ids of known call/video apps, mapped to display names.
    /// Prefix-matched: com.google.Chrome.helper -> (id: com.google.Chrome, name: Chrome).
    static let catalog: [(id: String, name: String)] = [
        ("us.zoom.xos",               "Zoom"),
        ("com.microsoft.teams2",      "Teams"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.FaceTime",        "FaceTime"),
        ("com.google.Chrome",         "Chrome"),
        ("com.apple.Safari",          "Safari"),
    ]

    // MARK: - Public Entry Point

    /// Never returns — registers CoreAudio property listeners and calls dispatchMain().
    static func watch(args: [String]) -> Never {
        let scopeBundleId = CLI.argValue(args, "--bundle-id")
        // callId bookkeeping across the close edge — captured by the closure
        // below (a `var` local, mutated only from MicWatcher's own serial
        // queue since `onEdge` is invoked exclusively from recompute()).
        var activeCallId: String?
        let watcher = MicWatcher(scopeBundleId: scopeBundleId, onEdge: { active, match in
            if active, let match {
                let callId = "\(match.bundleId)-\(Int(Date().timeIntervalSince1970 * 1000))"
                activeCallId = callId
                emit(["event": "call-open", "callId": callId, "app": match.app, "bundleId": match.bundleId])
                Meet42Trace.log("watch", "call-open",
                                ["callId": callId, "app": match.app, "bundleId": match.bundleId])
            } else {
                let callId = activeCallId ?? "unknown"
                emit(["event": "call-close", "callId": callId])
                Meet42Trace.log("watch", "call-close", ["callId": callId])
                activeCallId = nil
            }
        })
        watcher.start()
        let parentWatch = exitWithParent()
        // Keep watcher alive through dispatchMain (the listener blocks hold
        // a strong reference too, but this makes the intent explicit).
        withExtendedLifetime((watcher, parentWatch)) {
            dispatchMain()
        }
    }

    /// `watch` writes only on a mic edge, so it never noticed the app that spawned it was gone: every
    /// app quit or crash left one behind, each re-scanning CoreAudio every second for good (found: 12 at
    /// once, keeping coreaudiod busy; WOR-420). Exit as soon as the parent exits, and on the 1s backstop
    /// if it was already gone (reparented to launchd) before this source was armed.
    private static func exitWithParent() -> DispatchSourceProcess? {
        let parent = getppid()
        guard parent > 1 else { exit(0) }
        MicWatcher.parentPID = parent
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        source.setEventHandler {
            Meet42Trace.log("watch", "parent-exited", ["parent": Int(parent)])
            exit(0)
        }
        source.resume()
        return source
    }

    // MARK: - Emit

    /// The ONLY function that writes to stdout. Encodes the payload as a single
    /// JSON line and flushes immediately so the calendar widget sees it live.
    static func emit(_ payload: [String: String]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        ), let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }

    // MARK: - CoreAudio helpers (nonisolated — safe to call from any queue)

    /// All HAL process object IDs currently known to the system.
    nonisolated static func processIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }
        return ids
    }

    /// kAudioProcessPropertyIsRunningInput — true when the process holds mic input.
    nonisolated static func isRunningInput(_ processID: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var result = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processID, &addr, 0, nil, &size, &result)
        return status == noErr && result != 0
    }

    /// kAudioProcessPropertyBundleID — the CFString bundle id of the process.
    nonisolated static func processBundleID(_ processID: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var cfStr: Unmanaged<CFString>? = nil
        let status = AudioObjectGetPropertyData(processID, &addr, 0, nil, &dataSize, &cfStr)
        guard status == noErr, let str = cfStr?.takeRetainedValue() else { return nil }
        return str as String
    }

    /// True when any audio device with input streams is running somewhere, i.e. some process may be
    /// capturing a mic. One device-list read plus two reads per device: far fewer than a process scan.
    nonisolated static func anyInputDeviceRunning() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return true }   // unknown: scan, as before
        var devices = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &devices
        ) == noErr else { return true }

        for device in devices {
            var streamsAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streamsAddr, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0 else { continue }   // no input streams: not a mic
            var runningAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &runningAddr, 0, nil, &size, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }

    /// Returns the canonical (id, name) pair for a raw bundle id, or nil if
    /// the id is not in the call-app catalog. Prefix-matched so helpers like
    /// com.google.Chrome.helper map to the canonical Chrome entry.
    nonisolated static func canonicalEntry(
        for rawBundleID: String
    ) -> (id: String, name: String)? {
        catalog.first { rawBundleID == $0.id || rawBundleID.hasPrefix($0.id + ".") }
    }
}

// MARK: - MicWatcher

/// Holds all mutable detection state and the registered CoreAudio listener
/// blocks. Every method (and therefore every state mutation) runs exclusively
/// on `queue`, giving us lock-free safety without actors.
///
/// `meet42 watch` uses the same proven listener + 1s-backstop machinery for
/// global detection and bundle-scoped widget lifecycle observation. Recording
/// capture deliberately does not use this watcher; UI owners decide how mic
/// edges affect a meeting.
///
/// @unchecked Sendable: Swift can't verify the serial-queue discipline, but it
/// is enforced by construction — all entry points dispatch onto `queue`.
final class MicWatcher: @unchecked Sendable {

    let queue = DispatchQueue(label: "meet42.mic-watch")

    /// Restrict matching to this ONE bundle id (prefix-matched like
    /// `canonicalEntry`), or `nil` to match the whole `WatchCommand.catalog`.
    let scopeBundleId: String?

    /// Called on every active↔inactive edge with the new state and, when
    /// active, the matched (app, bundleId) pair.
    let onEdge: (Bool, (app: String, bundleId: String)?) -> Void

    // Guarded by `queue` — only ever mutated in methods called from `queue`.
    var registered = Set<AudioObjectID>()
    var wasActive  = false
    var hasComputed = false

    /// Backstop re-scan timer (see start()). Held so it stays alive.
    var backstopTimer: DispatchSourceTimer?

    /// The app that spawned `meet42 watch`; the backstop exits once it is no longer the parent.
    nonisolated(unsafe) static var parentPID: pid_t?

    init(
        scopeBundleId: String? = nil,
        onEdge: @escaping (Bool, (app: String, bundleId: String)?) -> Void
    ) {
        self.scopeBundleId = scopeBundleId
        self.onEdge = onEdge
    }

    // MARK: start

    /// Register the system process-list listener, seed per-process listeners,
    /// and do an initial recompute so any already-running call app is detected.
    /// Also arm a 1s backstop re-scan (see below).
    func start() {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, queue
        ) { [self] _, _ in
            self.syncPerProcessListeners()
            self.recompute()
        }

        // Seed: attach per-process listeners for all currently-alive processes
        // and compute the initial detection state.
        queue.sync {
            self.syncPerProcessListeners()
            self.recompute()
        }

        // Backstop re-scan. The per-process kAudioProcessPropertyIsRunningInput
        // listener does NOT reliably fire when a process that was ALREADY in the
        // list (e.g. a long-running Chrome helper) starts capturing the mic —
        // and there is no other OS notification for "this specific process just
        // started input while the input device is already in use". Without a
        // backstop, detection of such an open only happens when some UNRELATED
        // process appears/disappears and incidentally triggers recompute()
        // (observed: ~11s prompt latency). A cheap 1s re-scan closes that gap.
        //
        // This is NOT level-polling that re-fires: recompute() emits ONLY on the
        // aggregate open↔close edge, so the semantics stay "prompt once per
        // call". The scan is microseconds (read 2 properties over ~30 process
        // objects). The event listeners above still give sub-second latency for
        // the common fresh-process case; this only covers what they miss.
        //
        // Skipped while no input device is running anywhere (WOR-420): then no process can hold the mic,
        // so there is nothing to detect, and each scan is ~2 CoreAudio reads per process that land on
        // coreaudiod. A close edge still gets its one recompute; the listeners above stay armed.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [self] in
            if let parent = Self.parentPID, getppid() != parent { exit(0) }
            guard WatchCommand.anyInputDeviceRunning() else {
                if self.wasActive { self.recompute() }
                return
            }
            self.syncPerProcessListeners()
            self.recompute()
        }
        timer.resume()
        backstopTimer = timer

        Meet42Trace.log("watch", "listener-registered", [:])
    }

    // MARK: recompute

    /// Apply the match scope (whole catalog, or one bundle id) to the current
    /// process list and invoke `onEdge` on the aggregate empty↔non-empty edge
    /// only. Called exclusively from `queue`.
    func recompute() {
        let holders: [(app: String, bundleId: String)] = WatchCommand.processIDs()
            .compactMap { pid -> (app: String, bundleId: String)? in
                guard WatchCommand.isRunningInput(pid) else { return nil }
                guard let raw = WatchCommand.processBundleID(pid) else { return nil }
                if let scope = scopeBundleId {
                    guard raw == scope || raw.hasPrefix(scope + ".") else { return nil }
                    return (scope, raw)
                }
                guard let entry = WatchCommand.canonicalEntry(for: raw) else { return nil }
                return (entry.name, entry.id)
            }
        let active = !holders.isEmpty
        let isInitialScopedClose = !hasComputed && scopeBundleId != nil && !active
        hasComputed = true
        guard active != wasActive || isInitialScopedClose else { return }
        wasActive = active
        onEdge(active, holders.first)
    }

    // MARK: per-process listener management

    /// Register a kAudioProcessPropertyIsRunningInput listener for one process.
    /// Called exclusively from `queue`.
    func addInputListener(_ pid: AudioObjectID) {
        guard !registered.contains(pid) else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(pid, &addr, queue) { [self] _, _ in
            self.recompute()
        }
        registered.insert(pid)
        Meet42Trace.log("watch", "proc-added", ["procId": Int(pid)])
    }

    /// Keep registered in sync with the current process list: add listeners for
    /// new processes, remove bookkeeping entries for processes that vanished.
    /// (We can't unregister a CoreAudio listener without the original block ref,
    /// but the kernel won't deliver callbacks for dead objects — tidying the set
    /// prevents unbounded growth.) Called exclusively from `queue`.
    func syncPerProcessListeners() {
        let current = Set(WatchCommand.processIDs())
        for pid in current where !registered.contains(pid) {
            addInputListener(pid)
        }
        let removed = registered.subtracting(current)
        for pid in removed {
            registered.remove(pid)
            Meet42Trace.log("watch", "proc-removed", ["procId": Int(pid)])
        }
    }
}
