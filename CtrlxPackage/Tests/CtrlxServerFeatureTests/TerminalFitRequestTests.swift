import CtrlxCommon
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite("Terminal Fit completion")
struct TerminalFitRequestTests {
    private enum FitError: Error { case failed }

    @Test("Failed and unattempted split targets remain retryable", arguments: [nil, "host-a"] as [String?], [0, 1])
    func partialFailure(hostID: String?, failingIndex: Int) async throws {
        let requests = ["@1", "@2"].map {
            TerminalFitRequest(hostID: hostID, sessionName: "dev", windowTarget: $0, columns: 100, rows: 35)
        }
        var fit = TerminalTabFit()
        // Even a previous successful Fit at this size must not hide a new failure.
        for request in requests {
            fit.recordFit(for: request.target, request: request.resize)
        }
        var attempted: [String] = []
        var succeeded: [String] = []
        do {
            try await TerminalFitRequest.perform(requests, willStart: { request in
                fit.invalidateFit(for: request.target)
            }, resize: { request in
                attempted.append(request.windowTarget)
                if request.windowTarget == requests[failingIndex].windowTarget {
                    throw FitError.failed
                }
            }, didSucceed: { request in
                succeeded.append(request.windowTarget)
                fit.recordFit(for: request.target, request: request.resize)
            })
            Issue.record("Expected a Fit failure")
        } catch FitError.failed {
            #expect(attempted == requests.prefix(failingIndex + 1).map(\.windowTarget))
            #expect(succeeded == requests.prefix(failingIndex).map(\.windowTarget))
        }

        for (index, request) in requests.enumerated() {
            #expect(fit.takeRequest(for: request.target, isAvailable: true, isPresentationReady: true, measuredRequest: request.resize) == nil)
            fit.requestAfterViewportChange(request.target, measuredRequest: request.resize)
            let retry = fit.takeRequest(for: request.target, isAvailable: true, isPresentationReady: true, measuredRequest: request.resize)
            #expect(retry == (index < failingIndex ? nil : request.resize))
        }

        // Dismissing the error may re-fit only the focused left side. The right side
        // must remain clickable whether it failed or was never attempted.
        let left = requests[0]
        fit.request(left.target)
        #expect(fit.takeRequest(for: left.target, isAvailable: true, isPresentationReady: true, measuredRequest: left.resize) == left.resize)
        fit.recordFit(for: left.target, request: left.resize)
        let right = requests[1]
        fit.requestAfterViewportChange(right.target, measuredRequest: right.resize)
        #expect(fit.takeRequest(for: right.target, isAvailable: true, isPresentationReady: true, measuredRequest: right.resize) == right.resize)

        try await TerminalFitRequest.perform([right], willStart: { request in
            fit.invalidateFit(for: request.target)
        }, resize: { request in
            #expect(request.hostID == hostID && request.sessionName == "dev" && request.windowTarget == "@2")
        }, didSucceed: { request in
            fit.recordFit(for: request.target, request: request.resize)
        })
        fit.requestAfterViewportChange(right.target, measuredRequest: right.resize)
        #expect(fit.target == nil)
    }
}
