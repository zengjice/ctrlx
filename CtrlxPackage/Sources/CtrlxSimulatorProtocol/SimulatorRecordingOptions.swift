import Foundation

public struct SimulatorRecordingOptions: Sendable {
    public static let maximumBytes = 128 * 1024 * 1024
    public let output: URL
    public let seconds: Int

    public init(output: String, seconds: Int = 60) throws {
        guard output.hasPrefix("/"), !output.contains("\0"),
              URL(fileURLWithPath: output).pathExtension.lowercased() == "mp4",
              (1...60).contains(seconds) else {
            throw SimulatorFailure("record-start requires an absolute new .mp4 path and --seconds 1...60")
        }
        self.output = URL(fileURLWithPath: output).standardizedFileURL
        self.seconds = seconds
    }
}
