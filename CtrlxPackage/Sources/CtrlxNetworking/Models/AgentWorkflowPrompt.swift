import Foundation

/// Used by delivery and preview. Answers arrive in configured node order;
/// provider output is kept verbatim rather than summarized or truncated.
public enum AgentWorkflowPrompt {
    public struct Answer: Sendable {
        public let role: String
        public let round: Int
        public let text: String
        public let attachmentIDs: [UUID]

        public init(role: String, round: Int, text: String, attachmentIDs: [UUID] = []) {
            self.role = role
            self.round = round
            self.text = text
            self.attachmentIDs = attachmentIDs
        }
    }

    public static func compose(
        definition: AgentWorkflowDefinition, node: AgentWorkflowNode,
        answers: [Answer], invocationReference: String
    ) -> AgentWorkflowInput {
        var sections = [node.input.text, "Initial task:\n\(definition.initialInput.text)"]
        var attachments = node.input.attachmentIDs
        if node.id == definition.entryNodeID {
            attachments += definition.initialInput.attachmentIDs
        }
        for answer in answers {
            sections.append("Answer from \(answer.role) (round \(answer.round)):\n\(answer.text)")
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

    /// Before execution, upstream answers and the correlation UUID do not yet
    /// exist. The UI labels these placeholders instead of claiming an exact task.
    public static func preview(definition: AgentWorkflowDefinition, node: AgentWorkflowNode, round: Int) -> AgentWorkflowInput {
        let sources: [AgentWorkflowNode]
        let sourceRound: Int
        if node.id == definition.entryNodeID, round > 1, let loop = definition.loop {
            sources = definition.nodes.filter { $0.id == loop.finalNodeID }
            sourceRound = round - 1
        } else {
            sources = definition.upstream(of: node.id)
            sourceRound = round
        }
        return compose(
            definition: definition, node: node,
            answers: sources.map {
                .init(role: $0.name, round: sourceRound, text: "<Full final answer and shared artifacts will be inserted here after this Agent completes.>")
            }, invocationReference: "<assigned when this task is created>"
        )
    }
}
