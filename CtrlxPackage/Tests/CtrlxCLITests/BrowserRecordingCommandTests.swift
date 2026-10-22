import ArgumentParser
import Foundation
import Testing
@testable import CtrlxCLI

struct BrowserRecordingCommandTests {
    @Test
    func defaultsAndDurationBoundary() throws {
        let output = "/tmp/ctrlx-recording-\(UUID().uuidString).mp4"
        let defaults = try BrowserRecordStartCommand.parse(["--tab", UUID().uuidString, "--output", output])
        #expect(defaults.seconds == 600)
        #expect(defaults.fps == 10)
        for seconds in [1, 600] {
            let command = try BrowserRecordStartCommand.parse(["--tab", UUID().uuidString, "--output", output, "--seconds", "\(seconds)"])
            #expect(command.seconds == seconds)
        }
        for arguments in [["--seconds", "0"], ["--seconds", "601"], ["--fps", "0"], ["--fps", "31"]] {
            #expect(throws: (any Error).self) {
                try BrowserRecordStartCommand.parse(["--tab", UUID().uuidString, "--output", output] + arguments)
            }
        }
    }

    @Test
    func rejectsRelativeWrongFormatAndExistingDestinations() throws {
        for output in ["relative.mp4", "/tmp/video.webm", "/tmp/nul\0.mp4"] {
            #expect(throws: (any Error).self) {
                try BrowserRecordStartCommand.parse(["--tab", UUID().uuidString, "--output", output])
            }
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("preserve".utf8).write(to: output)
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(throws: (any Error).self) {
            try BrowserRecordStartCommand.parse(["--tab", UUID().uuidString, "--output", output.path])
        }
        #expect(try Data(contentsOf: output) == Data("preserve".utf8))
    }

    @Test
    func stopAndStatusPreserveExpectedRecordingIdentity() throws {
        let tab = UUID().uuidString, recording = UUID().uuidString
        let stop = try BrowserRecordStopCommand.parse(["--tab", tab, "--recording", recording])
        let status = try BrowserRecordStatusCommand.parse(["--tab", tab, "--recording", recording])
        #expect(stop.tab == tab && stop.recording == recording)
        #expect(status.tab == tab && status.recording == recording)
    }
}
