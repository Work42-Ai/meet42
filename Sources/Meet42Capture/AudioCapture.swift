// AudioCapture.swift — meet42's audio-only capture sources: system audio via a Core Audio process tap, and
// the microphone via AVAudioEngine.
//
// meet42 never records the screen, so it does not use ScreenCaptureKit (which would need the broad
// "Screen & System Audio Recording" permission). A Core Audio tap hears everything the Mac plays and needs
// only macOS's "System Audio Recording Only" permission, whose prompt names meet42 and says exactly that.
//
// Both sources deliver the same thing downstream consumers already expect: 16 kHz mono Float32 audio as
// `CMSampleBuffer`s, on a background queue.

import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation

// MARK: - System audio permission

/// macOS "System Audio Recording Only" (TCC service `kTCCServiceAudioCapture`).
///
/// There is no public API to read or request it, so this uses the TCC framework's `TCCAccessPreflight` /
/// `TCCAccessRequest`, the same calls the system's own tools use. If the framework or a symbol is missing
/// (a future macOS), the status degrades to "not determined" and the first capture attempt shows the prompt.
public enum SystemAudioPermission {

    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    // The callback is an Objective-C block: a Swift closure inside a @convention(c) type is passed as one.
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private nonisolated(unsafe) static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    public enum Status: Sendable, Equatable {
        case granted, denied, notDetermined
    }

    /// Current status. `TCCAccessPreflight` returns 0 (allowed), 1 (denied) or 2 (never asked).
    public static func status() -> Status {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .notDetermined }
        let preflight = unsafeBitCast(symbol, to: PreflightFn.self)
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the system prompt when the user has not decided yet and waits for the answer. When macOS has
    /// already recorded a decision it does not ask again and this just returns the current status.
    public static func request() async -> Status {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return status() }
        let requestAccess = unsafeBitCast(symbol, to: RequestFn.self)
        let granted: Bool = await withCheckedContinuation { continuation in
            requestAccess(service, nil) { allowed in continuation.resume(returning: allowed) }
        }
        return granted ? .granted : status()
    }
}

// MARK: - Errors

public enum AudioCaptureError: Error, LocalizedError, Sendable {
    case tapFailed(String, OSStatus)
    case noOutputDevice
    case microphoneUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .tapFailed(let step, let status):
            return "System audio capture failed at \(step) (OSStatus \(status))."
        case .noOutputDevice:
            return "There is no audio output device to tap."
        case .microphoneUnavailable(let reason):
            return "The microphone could not be started: \(reason)"
        }
    }
}

// MARK: - 16 kHz mono conversion

/// Converts arbitrary PCM to 16 kHz mono Float32 and wraps the result as a `CMSampleBuffer`.
/// One instance per source: the converter is stateful across buffers.
final class Mono16kConverter: @unchecked Sendable {
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    /// Converts `input` and returns a sample buffer stamped with `hostTime` (mach absolute time, in ticks).
    func convert(_ input: AVAudioPCMBuffer, hostTime: UInt64) -> CMSampleBuffer? {
        if converter == nil || inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: Self.outputFormat)
            inputFormat = input.format
        }
        guard let converter else { return nil }
        let ratio = Self.outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return Self.sampleBuffer(from: output, hostTime: hostTime)
    }

    /// Wraps a PCM buffer as an LPCM `CMSampleBuffer` whose data is copied, so the source buffer can be reused.
    static func sampleBuffer(from buffer: AVAudioPCMBuffer, hostTime: UInt64) -> CMSampleBuffer? {
        var description = buffer.format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }

        let timescale = Int32(description.mSampleRate)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: CMClockMakeHostTimeFromSystemUnits(hostTime),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: formatDescription, sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList
        ) == noErr else { return nil }
        return sampleBuffer
    }
}

// MARK: - System audio tap

/// Counts IO callbacks so the tap can log its first ones without flooding the log.
private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// Hears everything the Mac plays: a global Core Audio process tap, read through a private aggregate device.
/// Requires macOS 14.2+ and the "System Audio Recording Only" permission (prompted on first start).
final class SystemAudioTap: @unchecked Sendable {

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "meet42.capture.system-audio", qos: .userInitiated)
    private let converter = Mono16kConverter()

    func start(handler: @escaping @Sendable (CMSampleBuffer) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "meet42 system audio"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw AudioCaptureError.tapFailed("create tap", status) }

        guard let outputUID = Self.defaultOutputDeviceUID() else {
            stop()
            throw AudioCaptureError.noOutputDevice
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "meet42 system audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            stop()
            throw AudioCaptureError.tapFailed("create aggregate device", status)
        }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr, let tapFormat = AVAudioFormat(streamDescription: &format) else {
            stop()
            throw AudioCaptureError.tapFailed("read tap format", status)
        }

        let converter = self.converter
        Log.info("[SystemAudioTap] tap format: \(tapFormat)")
        let seen = CallbackCounter()
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inputData, _, _, _ in
            let call = seen.next()
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            if call == 1 { Log.info("[SystemAudioTap] receiving audio (\(list.count) input buffers per callback)") }
            // The aggregate device's input holds the main sub-device's own stream(s) as well as the tap, so
            // pick the buffer that carries the tap: the one with the tap's channel count (the last such one).
            guard let tapBuffer = list.last(where: { $0.mNumberChannels == tapFormat.channelCount }),
                  let source = tapBuffer.mData, tapBuffer.mDataByteSize > 0,
                  let pcm = AVAudioPCMBuffer(
                      pcmFormat: tapFormat,
                      frameCapacity: tapBuffer.mDataByteSize / tapFormat.streamDescription.pointee.mBytesPerFrame
                  ),
                  let destination = pcm.audioBufferList.pointee.mBuffers.mData else { return }
            memcpy(destination, source, Int(tapBuffer.mDataByteSize))
            pcm.frameLength = pcm.frameCapacity
            guard let sample = converter.convert(pcm, hostTime: mach_absolute_time()) else { return }
            handler(sample)
        }
        guard status == noErr else {
            stop()
            throw AudioCaptureError.tapFailed("create IO proc", status)
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stop()
            throw AudioCaptureError.tapFailed("start", status)
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultOutputDeviceUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return deviceUID(device)
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}

// MARK: - Microphone

/// The microphone ("You"): the system default input, or the device the user picked, through AVAudioEngine.
final class MicrophoneCapture: @unchecked Sendable {

    private let engine = AVAudioEngine()
    private let converter = Mono16kConverter()
    private var running = false

    /// `deviceUID` is an `AVCaptureDevice.uniqueID`; nil means the system default input.
    func start(deviceUID: String?, handler: @escaping @Sendable (CMSampleBuffer) -> Void) throws {
        if let deviceUID {
            guard let device = Self.audioDeviceID(forUID: deviceUID), let unit = engine.inputNode.audioUnit else {
                throw AudioCaptureError.microphoneUnavailable("device \(deviceUID) is not connected")
            }
            var id = device
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw AudioCaptureError.microphoneUnavailable("could not select device (OSStatus \(status))")
            }
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.microphoneUnavailable("this Mac has no input device")
        }
        let converter = self.converter
        // nil = the node's own format, so a device whose rate differs from what we probed cannot trap.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            guard let sample = converter.convert(buffer, hostTime: mach_absolute_time()) else { return }
            handler(sample)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw AudioCaptureError.microphoneUnavailable(error.localizedDescription)
        }
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var cfUID = uid as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &device
            )
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}
