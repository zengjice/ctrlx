import CtrlxNetworking

struct TerminalAgentModelOptions: Sendable {
    let snapshot: AgentModelSnapshot
    let hidden: AgentModelShortcuts

    var models: [AgentModelOption] {
        snapshot.models.filter { hidden.shows(model: $0, selection: snapshot.selection) }
    }

    var efforts: [String] {
        guard let model = snapshot.models.first(where: { $0.id == snapshot.selection?.model }) else { return [] }
        return model.efforts.filter { hidden.shows(effort: $0, selection: snapshot.selection) }
    }

    func selection(modelID: String) -> AgentModelSelection? {
        guard let model = snapshot.models.first(where: { $0.id == modelID }) else { return nil }
        let effort = snapshot.selection?.effort.flatMap { model.efforts.contains($0) ? $0 : nil } ?? model.defaultEffort
        return .init(model: model.id, effort: effort)
    }

    func selection(effort: String) -> AgentModelSelection? {
        guard
            let selection = snapshot.selection,
            let model = snapshot.models.first(where: { $0.id == selection.model }),
            model.efforts.contains(effort) else { return nil }
        return .init(model: model.id, effort: effort)
    }
}
