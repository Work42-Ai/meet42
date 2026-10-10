import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Meet42Capture

/// The capture sources hand downstream consumers 16 kHz mono Float32 `CMSampleBuffer`s whatever the device
/// format is. These tests cover that conversion without touching any audio hardware or permission.
@Suite struct AudioConversionTests {

    private func stereoBuffer(sampleRate: Double, frames: Int, value: Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: true
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        if frames > 0 {
            let samples = try #require(buffer.floatChannelData?[0])
            for index in 0..<(frames * 2) { samples[index] = value }
        }
        return buffer
    }

    @Test func stereo48kBecomesMono16k() throws {
        let converter = Mono16kConverter()
        let input = try stereoBuffer(sampleRate: 48_000, frames: 4_800, value: 0.5)
        let sample = try #require(converter.convert(input, hostTime: 1_000))

        let format = try #require(CMSampleBufferGetFormatDescription(sample))
        let description = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee
        #expect(description.mSampleRate == 16_000)
        #expect(description.mChannelsPerFrame == 1)
        #expect(description.mFormatID == kAudioFormatLinearPCM)
        // 100 ms of audio is 1,600 frames; the resampler holds back a few for its filter.
        let frames = CMSampleBufferGetNumSamples(sample)
        #expect(frames > 1_200 && frames <= 1_700)
    }

    @Test func convertedDataSurvivesTheRoundTripUsedByConsumers() throws {
        let converter = Mono16kConverter()
        let input = try stereoBuffer(sampleRate: 16_000, frames: 1_600, value: 0.25)
        let sample = try #require(converter.convert(input, hostTime: 1_000))

        // Exactly what MeetingTranscriptionEngine does with a buffer: copy the PCM out of the sample buffer.
        let format = try #require(CMSampleBufferGetFormatDescription(sample))
        let pcmFormat = AVAudioFormat(cmAudioFormatDescription: format)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        let copy = try #require(AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frames))
        copy.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: copy.mutableAudioBufferList
        )
        #expect(status == noErr)
        let samples = try #require(copy.floatChannelData?[0])
        #expect(frames > 1_000)
        #expect(abs(samples[Int(frames) / 2] - 0.25) < 0.05)
    }

    @Test func emptyInputProducesNoBuffer() throws {
        let converter = Mono16kConverter()
        let input = try stereoBuffer(sampleRate: 48_000, frames: 0, value: 0)
        #expect(converter.convert(input, hostTime: 1_000) == nil)
    }
}
