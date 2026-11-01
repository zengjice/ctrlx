import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@Suite("Relay quota recovery")
struct RelayAccessRecoveryTests {
    @Test("Recovery requires enough bytes for the rejected message and the same account")
    func allowance() {
        let failure = RelayAccessFailure(code: .quotaExceeded, message: "quota", quota: quota(used: 90), requiredBytes: 20)
        #expect(!RelayAccessRecovery.canResume(failure, status: RelayAccessStatus(metered: true, quota: quota(used: 90))))
        #expect(RelayAccessRecovery.canResume(failure, status: RelayAccessStatus(metered: true, quota: quota(used: 80))))
        #expect(!RelayAccessRecovery.canResume(failure, status: RelayAccessStatus(metered: true, quota: quota(used: 0, account: "another"))))
        #expect(!RelayAccessRecovery.canResume(failure, status: RelayAccessStatus(metered: false)))
    }

    @Test("Disabled, stale, or revoked states cannot resume; a new monthly allowance can")
    func states() {
        let previous = quota(used: 100, revision: 3)
        let failure = RelayAccessFailure(code: .quotaExceeded, message: "quota", quota: previous)
        #expect(!RelayAccessRecovery.canResume(failure, status: RelayAccessStatus(metered: true, quota: quota(used: 0, enabled: false, revision: 4))))
        #expect(!RelayAccessRecovery.canResume(failure, status: RelayAccessStatus(metered: true, quota: quota(used: 0, revision: 2))))
        #expect(RelayAccessRecovery.canResume(failure, status: RelayAccessStatus(metered: true, quota: quota(used: 0, period: "2026-12", revision: 3))))
        #expect(!RelayAccessRecovery.canPoll(RelayAccessFailure(code: .authenticationRequired, message: "revoked")))
        #expect(!RelayAccessRecovery.canResume(failure, status: RelayAccessStatus(metered: true, failure: RelayAccessFailure(code: .authenticationRequired, message: "revoked"))))
    }

    private func quota(used: Int64, enabled: Bool = true, account: String = "account", period: String = "2026-11", revision: Int64 = 3) -> RelayQuotaStatus {
        RelayQuotaStatus(
            accountID: account,
            accountName: "shared",
            enabled: enabled,
            period: period,
            resetsAt: Date(timeIntervalSince1970: 1_796_054_400),
            baseBytes: 100,
            extraBytes: 0,
            usedBytes: used,
            revision: revision
        )
    }
}
