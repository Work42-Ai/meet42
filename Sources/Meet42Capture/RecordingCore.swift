// RecordingCore.swift — meet42's recording core.
//
// The single entry point that owns a recording's audio capture. AUDIO ONLY — meet42 never records the screen:
//
//   .microphone  — mic / "You" channel (16 kHz mono), via AVAudioEngine (MicrophoneCapture)
//   .audio       — system audio / "Them" channel (16 kHz mono), via a Core Audio process tap (SystemAudioTap)
//
// The tap needs only macOS's "System Audio Recording Only" permission (no Screen Recording). See
// AudioCapture.swift.
//
// MULTI-SUBSCRIBER FAN-OUT API
// ----------------------------
// Several consumers (transcription, diarization) subscribe to the same channels without clobbering each other:
//
//   let token = RecordingCore.shared.addMicHandler { buf in … }
//   let token = RecordingCore.shared.addSystemAudioHandler { buf in … }
//   RecordingCore.shared.removeHandler(token)
//
// Tokens are opaque UInt64 values. removeHandler(_:) is safe from any queue and idempotent. Handlers run on
// the capture queues (nonisolated); fan-out is O(N subscribers) under an NSLock.
//
// Swift 6.2 strict concurrency; public methods are @MainActor. All logging goes through Log (stderr), never
// stdout.

import AVFoundation
import CoreMedia
import Foundation

// MARK: - RecordingCore Errors

/// Typed error naming the specific denied permission + recovery guidance,
/// fail loud, naming mic vs system audio.
public enum RecordingCoreError: Error, LocalizedError, Sendable {
    /// Microphone permission denied before capture started.
    case microphoneDenied(message: String)
    /// System Audio Recording permission denied before capture started.
    case systemAudioDenied
    /// A recording is already active; stop it before starting another.
    case alreadyRecording
    /// The audio capture failed to start.
    case streamStartFailed(underlying: any Error)
    /// A configuration error prevented capture setup.
    case configurationFailed(String)
    /// The chosen microphone device is not currently connected.
    case microphoneDeviceUnavailable(name: String, uid: String)

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied(let msg):
            return "Microphone permission denied: \(msg)"
        case .systemAudioDenied:
            return "System Audio Recording permission denied. Switch meet42 on in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only (`meet42 permissions open systemAudio`), then start meet42 again."
        case .alreadyRecording:
            return "A recording is already active. Stop the current recording before starting another."
        case .streamStartFailed(let e):
            return "Audio capture failed to start: \(e.localizedDescription)"
        case .configurationFailed(let reason):
            return "Recording configuration failed: \(reason)"
        case .microphoneDeviceUnavailable(let name, _):
            return "Selected microphone \"\(name)\" isn't connected. Reconnect it, or choose a different input device (or System Default) in Settings → Microphone, then try again."
        }
    }
}

// MARK: - Buffer handler types

/// Per-channel buffer handlers, delivered on the capture queues.
/// Both fire from nonisolated context — hop to @MainActor when needed.
public typealias MicBufferHandler       = @Sendable (CMSampleBuffer) -> Void
public typealias SystemAudioHandler     = @Sendable (CMSampleBuffer) -> Void

// MARK: - SubscriptionToken

/// Opaque token returned by addXxxHandler. Pass to removeHandler to unsubscribe.
public struct SubscriptionToken: Sendable, Hashable {
    let id: UInt64
    public init(_ id: UInt64) { self.id = id }
}

// MARK: - Recording state

/// The lifecycle state of an active RecordingCore session.
public enum RecordingCoreState: String, Sendable, Equatable {
    case idle
    case starting     // preflight + capture setup in progress
    case recording    // capture delivering buffers
    case stopping     // teardown in progress
}

// MARK: - Session info

/// Identifies a RecordingCore session to consumers.
public struct RecordingCoreSession: Sendable, Equatable {
    /// Arbitrary slug / label provided by the caller (flow slug, meeting id).
    public let sessionID: String
    /// The root directory where session artifacts (audio/, etc.) will be written.
    public let sessionDir: URL
    /// Recording kind written into `RecordingInfo` in state.json. "learn" for
    /// flow42 learn sessions; "meeting" for MeetingTranscriptionService captures.
    /// Defaults to "learn" so existing callers are unchanged.
    public let kind: String

    public init(sessionID: String, sessionDir: URL, kind: String = "learn") {
        self.sessionID = sessionID
        self.sessionDir = sessionDir
        self.kind = kind
    }
}

// MARK: - RecordingCore

/// The single shared in-app recording core.
///
/// Consumers (flow42 recording, MeetingTranscriptionService) call `start(session:)`
/// and register per-channel handlers before the stream fires.
///
/// ## Multi-subscriber fan-out
///
/// Use `addMicHandler(_:)` and `addSystemAudioHandler(_:)` to subscribe; each
/// returns a `SubscriptionToken`. Call `removeHandler(_:)` when done. Multiple
/// subscribers per channel are supported concurrently.
///
/// Example:
/// ```swift
/// let t = RecordingCore.shared.addMicHandler { buf in … }
/// // later:
/// RecordingCore.shared.removeHandler(t)
/// ```
///
/// The core reports state through `StateFile`/`DerivedState` so the existing
/// `StateClient` mtime-poll pipeline continues to drive UI (EdgeGlowView, recording glow).
///
/// All public methods are `@MainActor`; the buffer fan-out runs nonisolated on the capture queues.
@MainActor
public final class RecordingCore: NSObject, @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = RecordingCore()

    private override init() {
        super.init()
    }

    // MARK: - State

    private(set) public var state: RecordingCoreState = .idle
    private(set) public var activeSession: RecordingCoreSession?

    // MARK: - Multi-subscriber handler storage
    //
    // All subscriber dictionaries and the token counter are accessed exclusively
    // under streamLock (the same lock that guards the capture sources).
    //
    // Handlers are stored as [token: handler] dictionaries so O(1) removal.
    // Fan-out iterates the values() snapshot while NOT holding the lock to avoid
    // deadlocking if a handler itself calls removeHandler.

    private nonisolated(unsafe) var _nextToken: UInt64 = 1

    private nonisolated(unsafe) var _micHandlers:         [UInt64: MicBufferHandler]    = [:]
    private nonisolated(unsafe) var _systemAudioHandlers: [UInt64: SystemAudioHandler]  = [:]

    // MARK: - Subscribe / unsubscribe API

    /// Subscribe to `.microphone` sample buffers (mic / "You").
    ///
    /// - Parameter handler: Called on a capture queue.
    /// - Returns: A token. Pass to `removeHandler(_:)` to unsubscribe.
    public func addMicHandler(_ handler: @escaping MicBufferHandler) -> SubscriptionToken {
        let token = streamLock.withLock { () -> UInt64 in
            let id = _nextToken
            _nextToken &+= 1
            _micHandlers[id] = handler
            return id
        }
        return SubscriptionToken(token)
    }

    /// Subscribe to `.audio` (system audio / "Them") sample buffers.
    ///
    /// - Parameter handler: Called on a capture queue.
    /// - Returns: A token. Pass to `removeHandler(_:)` to unsubscribe.
    public func addSystemAudioHandler(_ handler: @escaping SystemAudioHandler) -> SubscriptionToken {
        let token = streamLock.withLock { () -> UInt64 in
            let id = _nextToken
            _nextToken &+= 1
            _systemAudioHandlers[id] = handler
            return id
        }
        return SubscriptionToken(token)
    }

    /// Unsubscribe a handler previously registered via addXxxHandler.
    ///
    /// Idempotent and safe to call from any queue (including a capture queue
    /// and deinit). Silently ignores unknown tokens.
    ///
    /// `nonisolated` so that a subscriber's deinit can call this without hopping
    /// to @MainActor — the implementation only touches nonisolated(unsafe) state
    /// under streamLock.
    nonisolated public func removeHandler(_ token: SubscriptionToken) {
        streamLock.withLock {
            _micHandlers.removeValue(forKey: token.id)
            _systemAudioHandlers.removeValue(forKey: token.id)
        }
    }

    // MARK: - Internal capture state

    private let streamLock = NSLock()
    private var systemTap: SystemAudioTap?
    private var microphone: MicrophoneCapture?

    // Buffer-in smoke counters (one per channel), guarded by streamLock.
    private nonisolated(unsafe) var _micBufferCount: Int = 0
    private nonisolated(unsafe) var _audioBufferCount: Int = 0

    // MARK: - Permission preflight (centralised, AC22)

    /// Preflight the microphone and system-audio permissions before starting capture. When one is undecided
    /// macOS shows its prompt here and this waits for the answer. Returns a typed `RecordingCoreError` naming
    /// the denied permission, so the caller fails loudly instead of recording silence.
    public func preflightPermissions() async -> RecordingCoreError? {
        // 1. Mic — only when this Mac has an input device at all. Without one there is nothing to record or
        //    to ask permission for, and the recording carries system audio only.
        if !MicInputDeviceStore.availableDevices().isEmpty,
           case .denied(let msg) = await Permission.microphone.preflight() {
            return .microphoneDenied(message: msg)
        }

        // 2. System audio.
        if case .denied = await Permission.systemAudio.preflight() {
            return .systemAudioDenied
        }

        return nil
    }

    // MARK: - Start

    /// Start the shared recording core for a new session.
    ///
    /// - Parameter session: Identifies the session (slug + dir).
    /// - Throws: `RecordingCoreError` if already recording, permission denied, or
    ///           audio capture fails to start.
    ///
    /// On success the state transitions `idle → recording` and the
    /// `StateFile.AppState` is updated so `StateClient` observers (EdgeGlowView etc.)
    /// see the change immediately.
    ///
    /// Downstream consumers (e.g. SpeechTranscriber) register their
    /// handlers via `addMicHandler`/`addSystemAudioHandler` before calling this.
    public func start(session: RecordingCoreSession) async throws {
        guard state == .idle else {
            throw RecordingCoreError.alreadyRecording
        }

        state = .starting
        Log.info("[RecordingCore] starting session=\(session.sessionID) dir=\(session.sessionDir.path)")

        // Preflight permissions (AC22).
        if let err = await preflightPermissions() {
            state = .idle
            Log.info("[RecordingCore] permission denied: \(err.localizedDescription)")
            throw err
        }

        // Resolve mic device selection (AC5 / AC6 / AC7).
        // If a specific device is selected but unavailable, fail loud now rather
        // than silently capturing the wrong (or empty) mic channel.
        let sel = MicInputDeviceStore.selected()
        let micDeviceID: String?
        if let sel {
            let available = MicInputDeviceStore.availableDevices()
            if !available.contains(where: { $0.uid == sel.uid }) {
                state = .idle
                throw RecordingCoreError.microphoneDeviceUnavailable(name: sel.name, uid: sel.uid)
            }
            micDeviceID = sel.uid
        } else {
            micDeviceID = nil
        }

        // System audio ("Them").
        let tap = SystemAudioTap()
        do {
            try tap.start { [weak self] buffer in self?.deliverSystemAudio(buffer) }
        } catch {
            state = .idle
            throw RecordingCoreError.streamStartFailed(underlying: error)
        }

        // Microphone ("You"). Not having one is not fatal: the recording still carries system audio.
        let mic = MicrophoneCapture()
        do {
            try mic.start(deviceUID: micDeviceID) { [weak self] buffer in self?.deliverMicrophone(buffer) }
            Log.info("[RecordingCore] microphone: \(micDeviceID ?? "System Default")")
        } catch {
            if micDeviceID != nil {
                // The user picked a specific device and it failed: do not silently record without it.
                tap.stop()
                state = .idle
                throw RecordingCoreError.streamStartFailed(underlying: error)
            }
            Log.info("[RecordingCore] no microphone — recording system audio only (\(error.localizedDescription))")
        }

        streamLock.withLock {
            systemTap = tap
            microphone = mic
        }
        activeSession = session
        state = .recording

        reportStateToStateFile(session: session)

        Log.info("[RecordingCore] audio capture started — system audio tap + microphone (audio only)")
    }

    // MARK: - Stop

    /// Stop the active recording session.
    ///
    /// Idempotent: calling stop when already idle is a no-op.
    /// Transitions state back to `idle` and clears the `StateFile` entry.
    @discardableResult
    public func stop() async -> RecordingCoreSession? {
        guard state == .recording || state == .starting else {
            Log.info("[RecordingCore] stop() called while state=\(state.rawValue) — no-op")
            return nil
        }

        let session = activeSession
        state = .stopping
        Log.info("[RecordingCore] stopping session=\(session?.sessionID ?? "<none>")")

        let (tap, mic) = streamLock.withLock { () -> (SystemAudioTap?, MicrophoneCapture?) in
            let existing = (systemTap, microphone)
            systemTap = nil
            microphone = nil
            return existing
        }
        mic?.stop()
        tap?.stop()

        let counts = streamLock.withLock {
            (_micBufferCount, _audioBufferCount)
        }
        Log.info("[RecordingCore] stopped — mic=\(counts.0) sysaudio=\(counts.1) buffers")

        activeSession = nil
        state = .idle

        // Clear state.json so the glow reverts to idle.
        clearStateFile()

        return session
    }

    // MARK: - Smoke path diagnostics

    /// Returns buffer counts received since the last start, keyed by channel.
    /// Useful for a smoke test: start, wait briefly, confirm both audio channels fired.
    public var bufferCounts: (mic: Int, systemAudio: Int) {
        streamLock.withLock { (_micBufferCount, _audioBufferCount) }
    }

    // MARK: - Fan-out

    nonisolated private func deliverSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        let handlers: [SystemAudioHandler] = streamLock.withLock {
            _audioBufferCount += 1
            return Array(_systemAudioHandlers.values)
        }
        for handler in handlers { handler(sampleBuffer) }
    }

    nonisolated private func deliverMicrophone(_ sampleBuffer: CMSampleBuffer) {
        let handlers: [MicBufferHandler] = streamLock.withLock {
            _micBufferCount += 1
            return Array(_micHandlers.values)
        }
        for handler in handlers { handler(sampleBuffer) }
    }

    // MARK: - Mic device change notification hook

    /// Called on @MainActor just before a live mic hot-swap replaces the
    /// mic device. Consumers that maintain state tied to a specific mic audio timeline
    /// (e.g. MeetingTranscriptionEngine's SpeechAnalyzer sessions) register here to
    /// finalize their current session and start a fresh one before the new device's
    /// buffers arrive.
    ///
    /// Set by MeetingTranscriptionEngine.setup() in the GUI process.
    /// nil in the flow42 CLI daemon (which has no SpeechAnalyzer to reset).
    ///
    /// WHY THIS HOOK EXISTS:
    /// Apple's Speech framework (SpeechAnalyzer / SpeechRecognizerWorker) hard-traps
    /// (EXC_BREAKPOINT in SpeechRecognizerWorker.preRunRecognition) when it receives
    /// audio from a different physical mic device on the same long-lived session.
    /// The fix is to finalize the old SpeechAnalyzer session and start a fresh one
    /// coordinated with the mic device swap — this hook is the coordination point.
    public var onMicDeviceWillChange: (@MainActor () async -> Void)?

    // MARK: - Live mic hot-swap (AC8 / AC10 / AC11)

    /// Apply the currently-persisted microphone selection to the active recording stream.
    ///
    /// - If a specific device is selected but not connected, throws
    ///   `RecordingCoreError.microphoneDeviceUnavailable` (AC10: caller decides how to
    ///   surface the warning — never kills the active meeting).
    /// - If no recording is active (`state != .recording`), returns without error;
    ///   the next `start()` call will read the store fresh.
    /// - When recording: notifies `onMicDeviceWillChange` observers first (so
    ///   MeetingTranscriptionEngine can finalize/reset its SpeechAnalyzer before the
    ///   device swap), then replaces the microphone source while system audio keeps
    ///   running. Every `_micHandlers`/`_systemAudioHandlers` subscription survives.
    public func applySelectedMicrophoneDevice() async throws {
        let sel = MicInputDeviceStore.selected()
        Log.info("[RecordingCore] applySelectedMicrophoneDevice: entry — state=\(state.rawValue) selection=\(sel?.name ?? "System Default")")

        // Compute the device ID to apply; fail loud if the chosen device is absent.
        let micDeviceID: String?
        if let sel {
            let available = MicInputDeviceStore.availableDevices()
            if !available.contains(where: { $0.uid == sel.uid }) {
                // AC10: throw so caller can surface an inline warning.
                // The recording is NOT stopped.
                throw RecordingCoreError.microphoneDeviceUnavailable(name: sel.name, uid: sel.uid)
            }
            micDeviceID = sel.uid
        } else {
            micDeviceID = nil
        }

        // No active recording — next start() reads the store.
        guard state == .recording else {
            Log.info("[RecordingCore] applySelectedMicrophoneDevice: state=\(state.rawValue), not recording — no-op")
            return
        }

        // Notify consumers that the mic source is about to change.
        // MeetingTranscriptionEngine uses this to finalize the current "You"
        // ChannelTranscriber/SpeechAnalyzer session and start a fresh one, so the new
        // device's audio lands on a clean session — preventing EXC_BREAKPOINT inside
        // Apple's private Speech framework (SpeechRecognizerWorker.preRunRecognition).
        // This must happen BEFORE the stream swap so the old analyzer is drained
        // before new-device buffers arrive.
        if let onWillChange = onMicDeviceWillChange {
            Log.info("[RecordingCore] applySelectedMicrophoneDevice: notifying onMicDeviceWillChange observers (hook is set)")
            await onWillChange()
            Log.info("[RecordingCore] applySelectedMicrophoneDevice: onMicDeviceWillChange callback returned — proceeding with stream swap")
        } else {
            Log.info("[RecordingCore] applySelectedMicrophoneDevice: onMicDeviceWillChange is nil — no observer (flow42 path or setup() not called)")
        }

        // Replace the microphone source in place; system audio keeps running and every subscription
        // (`_micHandlers` / `_systemAudioHandlers`) survives.
        let old = streamLock.withLock { () -> MicrophoneCapture? in
            let existing = microphone
            microphone = nil
            return existing
        }
        old?.stop()

        let replacement = MicrophoneCapture()
        do {
            try replacement.start(deviceUID: micDeviceID) { [weak self] buffer in self?.deliverMicrophone(buffer) }
            streamLock.withLock { microphone = replacement }
            Log.info("[RecordingCore] applySelectedMicrophoneDevice: switched to \(micDeviceID ?? "System Default")")
        } catch {
            Log.info("[RecordingCore] applySelectedMicrophoneDevice: could not start the new microphone: \(error.localizedDescription)")
            throw RecordingCoreError.streamStartFailed(underlying: error)
        }
    }

    // MARK: - State reporting (no-op in standalone meet42)

    /// In work42 this wrote a `RecordingInfo` entry to the shared `state.json`
    /// so cross-process `StateClient` observers (the GUI edge-glow) could see
    /// `DerivedState.recording` immediately. The standalone meet42 capture
    /// engine has no such cross-process consumer (that work42 orchestration is
    /// replaced by meet42 CLI verbs), so this is intentionally a no-op kept as
    /// a seam for a future local status surface.
    private func reportStateToStateFile(session: RecordingCoreSession) {
        Log.info("[RecordingCore] recording started → session=\(session.sessionID) kind=\(session.kind)")
    }

    /// Counterpart to `reportStateToStateFile` — no-op in standalone meet42.
    private func clearStateFile() {
        Log.info("[RecordingCore] recording cleared → idle")
    }
}
