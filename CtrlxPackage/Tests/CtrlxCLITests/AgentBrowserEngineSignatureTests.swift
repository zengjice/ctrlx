import Testing
@testable import CtrlxCLI

struct AgentBrowserEngineSignatureTests {
    @Test
    func developerIDRequirementParsesAndRejectsInvalidTeamIDs() throws {
        _ = try AgentBrowserEngineSignature.requirement(team: "ABCDEF1234")
        for team in ["", "short", "ABCDEFGHIJK", "TEAM\" or true", "ABCDEFGHIJ\n"] {
            #expect(throws: AgentBrowserTransport.Failure.self) { try AgentBrowserEngineSignature.requirement(team: team) }
        }
    }
}
