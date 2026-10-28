#if os(macOS)
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxCommon

    struct AgentModelProcessEnvironmentTests {
        @Test
        func modelProbeDoesNotInheritHostProviderOrHome() async throws {
            try await withDependencies {
                $0.continuousClock = ContinuousClock()
            } operation: {
                let result = try await ProcessRunner.liveValue.runWithExactEnvironment(
                    "/usr/bin/env", [], ["CTRLX_MODEL_TEST": "target-pane"], 5, 4_096, nil
                )
                #expect(result.isSuccess)
                #expect(result.stdoutString == "CTRLX_MODEL_TEST=target-pane\n")
            }
        }
    }
#endif
