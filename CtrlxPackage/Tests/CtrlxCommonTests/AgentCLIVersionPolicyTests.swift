import CtrlxCommon
import Foundation
import Testing

struct AgentCLIVersionPolicyTests {
    @Test(arguments: [
        (AgentCLIVersionPolicy.codex, "codex-cli ", "", "0.170.0", "codex-cli 0.160.x–0.179.x (stable)"),
        (.claudeCode, "", " (Claude Code)", "2.1.327", "Claude Code 2.1.300–2.1.399 (stable)"),
        (.traex, "traecli ", "", "0.213.1", "traecli 0.213.x–0.219.x (stable)"),
    ])
    func stableVersionsAndDiagnostics(policy: AgentCLIVersionPolicy, prefix: String, suffix: String, number: String, range: String) {
        let version = prefix + number + suffix
        #expect(policy.supportedVersions == range)
        #expect(policy.supports(version))
        #expect(policy.automaticResumeUnavailableReason(version) == nil)
        #expect(policy.automaticResumeUnavailableReason(nil)?.contains(range) == true)
        #expect(policy.automaticResumeUnavailableReason("") != nil)
        #expect(!policy.supports(number))
        for malformed in [
            number + "-beta", number + "+build", number + ".1", number + "\n",
            "0" + number, "+" + number, " " + number,
            number.replacingOccurrences(of: ".", with: ".."),
            "999999999999999999999999999999999999.1.0",
        ] {
            #expect(!policy.supports(prefix + malformed + suffix))
        }
        #expect(!policy.supports(" " + version))
        #expect(!policy.supports(version + "\n"))
    }
}
