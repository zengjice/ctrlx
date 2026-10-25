import AVFoundation
import Foundation
import Testing
@testable import CtrlxCommon

struct SpeechAudioFileConverterTests {
    @Test(arguments: [22_050.0, 44_100.0, 48_000.0])
    func recordingIsResampledWithoutDroppingTheEnd(sampleRate: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-speech-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("speech.wav")
        let destination = directory.appendingPathComponent("converted.caf")
        let inputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let outputFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        try writeFixture(source, format: inputFormat)
        let original = try Data(contentsOf: source)

        try await SpeechAudioFileConverter.liveValue.convert(source, destination, outputFormat)

        let result = try AVAudioFile(forReading: destination, commonFormat: outputFormat.commonFormat, interleaved: outputFormat.isInterleaved)
        #expect(result.processingFormat == outputFormat)
        #expect(abs(result.length - 16_000) <= 1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(result.length)))
        try result.read(into: buffer)
        let samples = try #require(buffer.int16ChannelData)[0]
        let tail = (Int(buffer.frameLength) - 800)..<Int(buffer.frameLength)
        #expect(tail.map { abs(Int(samples[$0])) }.max() ?? 0 > 1_000)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test
    func cancellationBeforeConversionDoesNotCreateAnOutput() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-cancelled-speech-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: destination) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await SpeechAudioFileConverter.liveValue.convert(URL(fileURLWithPath: "/unused.wav"), destination, format)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    private func writeFixture(_ url: URL, format: AVAudioFormat) throws {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)))
        buffer.frameLength = buffer.frameCapacity
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            // The last 100 ms must survive the converter's end-of-stream drain.
            let value: Float = frame > Int(buffer.frameLength) * 9 / 10 ? 0.25 : 0
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = value
            }
        }
        try file.write(from: buffer)
    }
}
