import Foundation
import Security

enum AgentBrowserEngineSignature {
    static let developerID = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    static func requirement(team: String) throws -> SecRequirement {
        guard team.utf8.count == 10, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw failure }
        let identifier = "com.ctrlx.agent-browser-engine.\(ManagedAgentBrowser.sha256)"
        return try parse("\(developerID) and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\"")
    }

    private static func parse(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        guard
            SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
            let requirement else { throw failure }
        return requirement
    }

    static func verify(_ binary: URL) throws {
        var own: SecCode?
        var ownStatic: SecStaticCode?
        var information: CFDictionary?
        guard
            SecCodeCopySelf([], &own) == errSecSuccess, let own,
            try SecCodeCheckValidity(own, [], parse(developerID)) == errSecSuccess,
            SecCodeCopyStaticCode(own, [], &ownStatic) == errSecSuccess, let ownStatic,
            SecCodeCopySigningInformation(ownStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
            let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { throw failure }
        var engine: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(binary as CFURL, [], &engine) == errSecSuccess, let engine,
            try SecStaticCodeCheckValidity(engine, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement(team: team)) == errSecSuccess else { throw failure }
    }

    private static var failure: AgentBrowserTransport.Failure {
        .init("Bundled vercel engine is not the pinned upstream binary or its verified Developer ID build from this CtrlX team; not executed.")
    }
}
