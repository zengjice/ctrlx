import CtrlxNetworking
import Testing
@testable import CtrlxFeature

struct TerminalAgentModelOptionsTests {
    private let models: [AgentModelOption] = [
        .init(id: "first", name: "First", efforts: ["low", "high"], defaultEffort: "low"),
        .init(id: "second", name: "Second", efforts: ["low", "high"], defaultEffort: "low"),
        .init(id: "third", name: "Third", efforts: ["medium"], defaultEffort: "medium"),
        .init(id: "plain", name: "Plain", efforts: [], defaultEffort: nil),
    ]

    private func options(selection: AgentModelSelection? = .init(model: "first", effort: "high"), hidden: AgentModelShortcuts = .init()) -> TerminalAgentModelOptions {
        .init(snapshot: .init(runtimeID: "runtime", models: models, selection: selection, unavailableReason: nil), hidden: hidden)
    }

    @Test("Model changes preserve a supported effort and otherwise use the new model's default")
    func selectsModel() {
        #expect(options().selection(modelID: "second") == .init(model: "second", effort: "high"))
        #expect(options().selection(modelID: "third") == .init(model: "third", effort: "medium"))
        #expect(options().selection(modelID: "plain") == .init(model: "plain", effort: nil))
        #expect(options(selection: nil).selection(modelID: "second") == .init(model: "second", effort: "low"))
        #expect(options().selection(modelID: "missing") == nil)
    }

    @Test("Effort choices belong to the currently selected model")
    func selectsEffort() {
        #expect(options().efforts == ["low", "high"])
        #expect(options().selection(effort: "low") == .init(model: "first", effort: "low"))
        #expect(options().selection(effort: "medium") == nil)
        #expect(options(selection: nil).efforts.isEmpty)
        #expect(options(selection: nil).selection(effort: "high") == nil)
        #expect(options(selection: .init(model: "missing", effort: "high")).selection(effort: "high") == nil)
    }

    @Test("Host shortcut visibility preferences never hide the current model or effort")
    func visibility() {
        let hidden = AgentModelShortcuts(models: ["first", "second"], efforts: ["low", "high"])
        #expect(options(hidden: hidden).models.map(\.id) == ["first", "third", "plain"])
        #expect(options(hidden: hidden).efforts == ["high"])
        #expect(options(selection: nil, hidden: hidden).models.map(\.id) == ["third", "plain"])
    }
}
