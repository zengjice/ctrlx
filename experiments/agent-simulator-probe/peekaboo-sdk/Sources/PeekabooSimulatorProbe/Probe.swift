import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

@main
struct PeekabooSimulatorProbe {
    struct Observation: Encodable {
        let elapsedMilliseconds: Double
        let outcome: DesktopActionOutcome?
        let result: DesktopObservationResult
    }

    enum ProbeError: Error {
        case usage
        case wrongWindowOwner
        case missingPermissions
    }

    @MainActor
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let permissions = PermissionsService()
            if arguments == ["permissions"] {
                try self.emit(permissions.checkAllPermissions())
                return
            }
            guard arguments.count == 3, arguments[0] == "observe",
                  let pid = Int32(arguments[1]), pid > 0,
                  let windowID = CGWindowID(arguments[2]), windowID > 0
            else {
                throw ProbeError.usage
            }

            guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID)
                as? [[String: Any]],
                windows.contains(where: {
                    ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID &&
                        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                })
            else {
                throw ProbeError.wrongWindowOwner
            }
            guard permissions.checkAllPermissions().allGranted else {
                throw ProbeError.missingPermissions
            }

            let logger = LoggingService(subsystem: "com.ctrlx.peekaboo-simulator-probe")
            let automation = UIAutomationService()
            let observer = DesktopObservationService(
                screenCapture: ScreenCaptureService(loggingService: logger),
                automation: automation,
                applications: ApplicationService(permissions: permissions))
            let request = DesktopObservationRequest(
                target: .pid(pid, window: .id(windowID)),
                capture: DesktopCaptureOptions(engine: .modern),
                detection: DesktopDetectionOptions(
                    traversalBudget: AXTraversalBudget(maxDepth: 32, maxElementCount: 200),
                    requiresFreshAccessibilityTree: true),
                output: DesktopObservationOutputOptions(),
                timeout: DesktopObservationTimeouts(overall: 5, detection: 2))
            let clock = ContinuousClock()
            let start = clock.now
            let action = try await observer.observeActionResult(request)
            let elapsed = start.duration(to: clock.now).components
            try self.emit(Observation(
                elapsedMilliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
                outcome: action.outcome,
                result: action.payload.withoutImageData()))
        } catch {
            let message = "\(error)\nUsage: peekaboo-simulator-probe permissions | observe PID WINDOW_ID\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }

    static func emit(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
