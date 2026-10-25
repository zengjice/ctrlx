import Foundation
import Testing
@testable import CtrlxNetworking

struct CtrlXAppUpdateWireTests {
    @Test
    func installCommandAndStateRoundTrip() throws {
        let state = CtrlXAppUpdateState(
            phase: .available,
            currentVersion: "3.0.98",
            currentBuild: "31",
            latestVersion: "3.0.99",
            latestBuild: "32",
            latestBuildStamp: "20261024-150000",
            checkedAt: Date(timeIntervalSince1970: 1_000_000),
            canInstall: true
        )
        let install = InstallCtrlXAppUpdate(version: "3.0.99", build: "32")
        let command = CommandMessage(paneId: "", command: install.commandType)

        let decodedCommand = try JSONDecoder().decode(
            CommandMessage.self,
            from: JSONEncoder().encode(command)
        )
        #expect(decodedCommand.command == install.commandType)
        #expect(decodedCommand.command.requiresResponse)

        let response = CommandResponseMessage(
            commandId: command.id,
            success: true,
            ctrlXAppUpdate: state
        )
        let decodedResponse = try JSONDecoder().decode(
            CommandResponseMessage.self,
            from: JSONEncoder().encode(response)
        )
        #expect(decodedResponse.ctrlXAppUpdate == state)
    }

    @Test
    func sessionStateCapabilityIsAdditiveAndSurvivesRebinding() throws {
        let oldData = Data(#"{"pairId":"old","paneStates":{},"homeDirectory":""}"#.utf8)
        let old = try JSONDecoder().decode(SessionStateMessage.self, from: oldData)
        #expect(old.supportsCtrlXAppUpdate == nil)
        #expect(old.ctrlXAppUpdate == nil)

        let state = CtrlXAppUpdateState(
            phase: .upToDate,
            currentVersion: "3.0.98",
            currentBuild: "31",
            latestVersion: "3.0.98",
            latestBuild: "31"
        )
        let modern = SessionStateMessage(
            pairId: "a",
            paneStates: [:],
            supportsCtrlXAppUpdate: true,
            ctrlXAppUpdate: state
        )
        let copy = try JSONDecoder().decode(
            SessionStateMessage.self,
            from: JSONEncoder().encode(modern.withPairId("b"))
        )
        #expect(copy.pairId == "b")
        #expect(copy.supportsCtrlXAppUpdate == true)
        #expect(copy.ctrlXAppUpdate == state)
    }
}
