import Foundation
import Testing
@testable import CtrlxNetworking

struct AgentModelCatalogWarningTests {
    @Test("Catalog warnings remain optional for older peers and do not disable valid selections")
    func compatibility() throws {
        let old = Data(#"{"runtimeID":"runtime","models":[],"unavailableReason":null}"#.utf8)
        #expect(try JSONDecoder().decode(AgentModelSnapshot.self, from: old).catalogWarning == nil)
        let snapshot = AgentModelSnapshot(runtimeID: "runtime", models: [.init(id: "model", name: "Model", efforts: [], defaultEffort: nil)], selection: .init(model: "model", effort: nil), unavailableReason: nil, catalogWarning: "Using the previous list")
        let bytes = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(AgentModelSnapshot.self, from: bytes) == snapshot)
        struct OlderSnapshot: Decodable { let runtimeID: String
            let unavailableReason: String?
        }
        #expect(try JSONDecoder().decode(OlderSnapshot.self, from: bytes).unavailableReason == nil)
    }
}
