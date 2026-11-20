import Dependencies
import DependenciesMacros
import Foundation
import IOKit.pwr_mgt
import Logging

/// A dependency for managing system sleep prevention.
///
/// Wraps IOKit sleep assertion APIs so they can be controlled in tests.
/// Use `@Dependency(SleepPreventionService.self)` to access it.
@DependencyClient
public struct SleepPreventionService: Sendable {
    /// Holds an idle sleep assertion until disabled.
    public var setEnabled: @MainActor @Sendable (_ isEnabled: Bool) -> Void
}

// MARK: - DependencyKey

extension SleepPreventionService: DependencyKey {
    public static var previewValue: SleepPreventionService {
        SleepPreventionService(setEnabled: { _ in })
    }

    public static var liveValue: SleepPreventionService {
        let manager = LiveSleepPreventionManager()

        return SleepPreventionService(setEnabled: { manager.setEnabled($0) })
    }
}

// MARK: - Live Implementation

/// Shares isolation with the setting and app lifecycle so changes apply in order.
@MainActor
final private class LiveSleepPreventionManager {
    private var assertionID: IOPMAssertionID = 0
    private let logger = Logger(label: "com.jicezeng.ctrlx.sleep-prevention")

    nonisolated init() { }

    deinit {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        if isEnabled && assertionID == 0 {
            acquireAssertion()
        } else if !isEnabled && assertionID != 0 {
            releaseAssertion()
        }
    }

    private func acquireAssertion() {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "CtrlX: Keep this Mac awake" as CFString,
            &id
        )

        if result == kIOReturnSuccess {
            assertionID = id
        } else {
            logger.warning("Failed to acquire sleep prevention assertion: \(result)")
        }
    }

    private func releaseAssertion() {
        let result = IOPMAssertionRelease(assertionID)
        if result == kIOReturnSuccess {
            assertionID = 0
        } else {
            logger.warning("Failed to release sleep prevention assertion: \(result)")
        }
    }
}
