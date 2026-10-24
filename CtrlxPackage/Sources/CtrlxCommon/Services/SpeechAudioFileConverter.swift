import AVFoundation
import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct SpeechAudioFileConverter: Sendable {
    var convert: @Sendable (_ source: URL, _ destination: URL, _ format: AVAudioFormat) async throws -> Void
}

extension SpeechAudioFileConverter: DependencyKey {
    static let liveValue = Self(convert: convertFile)

    @concurrent
    private static func convertFile(_ source: URL, _ destination: URL, _ format: AVAudioFormat) async throws {
        try Task.checkCancellation()
        let input = try AVAudioFile(forReading: source)
        guard
            let converter = AVAudioConverter(from: input.processingFormat, to: format),
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4_096),
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)
        else { throw ConversionError.unavailable }
        let output = try AVAudioFile(
            forWriting: destination,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        while true {
            try Task.checkCancellation()
            var readError: (any Error)?
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, status in
                do {
                    try Task.checkCancellation()
                    let remaining = input.length - input.framePosition
                    guard remaining > 0 else {
                        status.pointee = .endOfStream
                        return nil
                    }
                    let count = AVAudioFrameCount(min(AVAudioFramePosition(min(requested, inputBuffer.frameCapacity)), remaining))
                    try input.read(into: inputBuffer, frameCount: count)
                    status.pointee = inputBuffer.frameLength == 0 ? .endOfStream : .haveData
                    return inputBuffer.frameLength == 0 ? nil : inputBuffer
                } catch {
                    readError = error
                    status.pointee = .noDataNow
                    return nil
                }
            }
            if let readError {
                throw readError
            }
            if let conversionError {
                throw conversionError
            }
            guard status != .error else { throw ConversionError.failed }
            if outputBuffer.frameLength > 0 {
                try output.write(from: outputBuffer)
            }
            // Drain the converter's final buffered samples before finishing.
            if status == .endOfStream {
                return
            }
        }
    }

    private enum ConversionError: LocalizedError {
        case unavailable
        case failed

        var errorDescription: String? {
            switch self {
            case .unavailable: "Unable to convert this recording to a supported speech audio format."
            case .failed: "Audio conversion failed before speech recognition could finish."
            }
        }
    }
}
