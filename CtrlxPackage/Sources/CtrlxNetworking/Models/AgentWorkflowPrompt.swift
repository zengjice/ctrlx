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

    public static func submittedText(_ input: AgentWorkflowInput, pluginID: String, imageNumbers: [Int]) -> String {
        guard !imageNumbers.isEmpty else { return input.text }
        let images = imageNumbers.map { "[Image #\($0)]" }.joined(separator: " ")
        return images + (pluginID == "claude-code" ? "" : " ") + input.text
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
        var context = ["[CtrlX workflow invocation: \(invocationReference)]"]
        if node.completion == .explicit {
            context.append("This step may span multiple replies. When its task is complete, run: ctrlx workflow complete-step --invocation \(invocationReference). Then provide the final result. Discussion or a proposal alone does not hand off the step.")
        }
        if node.allowsFinish {
            context.append("May end workflow: ctrlx workflow finish --invocation \(invocationReference) --reason \"<reason>\"")
        }
        sections.append(context.joined(separator: "\n"))
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
