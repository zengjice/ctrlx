import CtrlxNetworking
import Foundation

public enum RelayAccessRecovery {
    public static func canPoll(_ failure: RelayAccessFailure) -> Bool {
        switch failure.code {
        case .quotaExceeded,
             .accountDisabled,
             .unavailable,
             .rateLimited: true
        case .authenticationRequired,
             .accessDenied: false
        }
    }

    public static func canResume(_ failure: RelayAccessFailure, status: RelayAccessStatus) -> Bool {
        guard
            canPoll(failure), status.metered, status.failure == nil,
            let quota = status.quota, quota.enabled,
            quota.remainingBytes >= max(1, failure.requiredBytes ?? 1) else { return false }
        if let previous = failure.quota {
            guard
                previous.accountID == quota.accountID, quota.period >= previous.period,
                quota.revision >= previous.revision else { return false }
        }
        return true
    }
}
