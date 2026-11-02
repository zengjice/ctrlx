import Foundation

/// Used by delivery and preview. Answers arrive in configured node order;
/// provider output is kept verbatim rather than summarized or truncated.
public enum AgentWorkflowPrompt {
    public struct Answer: Sendable {
        public let role: String
        public let round: Int
        public let text: String
        public let attachmentIDs: [UUID]
        public let kind: AgentWorkflowNode.Kind

        public init(role: String, round: Int, text: String, attachmentIDs: [UUID] = [], kind: AgentWorkflowNode.Kind = .agent) {
            self.role = role
            self.round = round
            self.text = text
            self.attachmentIDs = attachmentIDs
            self.kind = kind
        }
    }

    public static func compose(
        definition: AgentWorkflowDefinition, node: AgentWorkflowNode,
        answers: [Answer], invocationReference: String
    ) -> AgentWorkflowInput {
        if node.kind == .content {
            return contentOutput(definition: definition, node: node, answers: answers)
        }
        let initial = definition.initialTask(for: node)
        var sections = [node.input.text]
        var attachments = node.input.attachmentIDs
        if initial != .omit {
            sections.append("Initial task:\n\(definition.initialInput.text)")
        }
        if initial == .textAndAttachments {
            attachments += definition.initialInput.attachmentIDs
        }
        for answer in answers {
            sections.append("\(answer.kind == .content ? "Content" : "Answer") from \(answer.role) (round \(answer.round)):\n\(answer.text)")
            attachments += answer.attachmentIDs
        }
        if !attachments.isEmpty {
            sections.append("This task includes authorized attachments. Before answering, run: ctrlx workflow attachments --invocation \(invocationReference) --json. Read every returned image with your image-reading tool and every text file in full. If a file cannot be read, ask for help; do not claim to have inspected it.")
        }
        sections.append("To hand off a file, save it and run: ctrlx workflow share --invocation \(invocationReference) --file <local-file> --json. Share each required artifact before your final answer. This snapshots the file for downstream tasks; mentioning a path alone does not share it. If sharing fails, report the error rather than claiming delivery.")
        if node.allowsFinish {
            sections.append("You may end this workflow by running: ctrlx workflow finish --invocation \(invocationReference) --reason \"your conclusion\". Then provide your final answer.")
        }
        sections.append("[CtrlX workflow invocation: \(invocationReference)]")
        var seen: Set<UUID> = []
        return .init(
            text: sections.filter { !$0.isEmpty }.joined(separator: "\n\n"),
            attachmentIDs: attachments.filter { seen.insert($0).inserted }
        )
    }

    /// Content nodes forward task material only. Invocation helper commands
    /// are added when a later Agent task is composed.
    private static func contentOutput(
        definition: AgentWorkflowDefinition, node: AgentWorkflowNode, answers: [Answer]
    ) -> AgentWorkflowInput {
        var sections = [node.input.text]
        var attachments = node.input.attachmentIDs
        let initial = definition.initialTask(for: node)
        if initial != .omit {
            if !definition.initialInput.text.isEmpty {
                sections.append("Initial task:\n\(definition.initialInput.text)")
            }
        }
        if initial == .textAndAttachments {
            attachments += definition.initialInput.attachmentIDs
        }
        for answer in answers {
            sections.append("Output from \(answer.role) (round \(answer.round)):\n\(answer.text)")
            attachments += answer.attachmentIDs
        }
        var seen: Set<UUID> = []
        return .init(text: sections.filter { !$0.isEmpty }.joined(separator: "\n\n"), attachmentIDs: attachments.filter { seen.insert($0).inserted })
    }

    /// Before execution, upstream answers and the correlation UUID do not yet
    /// exist. The UI labels these placeholders instead of claiming an exact task.
    public static func preview(definition: AgentWorkflowDefinition, node: AgentWorkflowNode, round: Int) -> AgentWorkflowInput {
        guard definition.activeNodeIDs(round: round).contains(node.id) else { return .init() }
        let sources: [AgentWorkflowNode]
        let sourceRound: Int
        if node.id == definition.entryNodeID(round: round), round > 1, let loop = definition.loop {
            sources = definition.nodes.filter { $0.id == loop.finalNodeID && loop.includesResult }
            sourceRound = round - 1
        } else {
            let sourceIDs = Set(definition.edges.filter { $0.target == node.id && $0.includesResult }.map(\.source))
            sources = definition.nodes.filter { sourceIDs.contains($0.id) }
            sourceRound = round
        }
        return compose(
            definition: definition, node: node,
            answers: sources.map {
                .init(role: $0.name, round: sourceRound, text: "<Full output and attachments will be inserted here after this node completes.>", kind: $0.kind)
            }, invocationReference: "<assigned when this task is created>"
        )
    }
}
