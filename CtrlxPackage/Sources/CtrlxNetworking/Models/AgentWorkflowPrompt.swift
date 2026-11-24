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
        if let exit = definition.loopExit, exit.source == node.id {
            context.append(loopExitInstructions(definition: definition, exit: exit, invocation: invocationReference))
        } else if node.allowsFinish {
            context.append("May end workflow: ctrlx workflow finish --invocation \(invocationReference) --reason \"<reason>\"")
        }
        sections.append(context.joined(separator: "\n"))
        var seen: Set<UUID> = []
        return .init(
            text: sections.filter { !$0.isEmpty }.joined(separator: "\n\n"),
            attachmentIDs: attachments.filter { seen.insert($0).inserted }
        )
    }

    public static func continuation(definition: AgentWorkflowDefinition, nodeID: UUID, invocationID: UUID) -> String {
        let invocation = invocationID.uuidString
        let completion: String
        if let exit = definition.loopExit, exit.source == nodeID {
            completion = """
            \(loopExitInstructions(definition: definition, exit: exit, invocation: invocation))
            If the task is complete and the approval condition is not met, run ctrlx workflow complete-step --invocation \(invocation), then provide the final result.
            """
        } else {
            completion = "If the task is already complete, do not repeat the work: run ctrlx workflow complete-step --invocation \(invocation), then provide the final result."
        }
        return """
        Continue the current workflow step using its existing task and instructions. \(completion) Otherwise continue the remaining work, respecting any outstanding questions or required approvals.

        [CtrlX workflow invocation: \(invocation)]
        """
    }

    private static func loopExitInstructions(definition: AgentWorkflowDefinition, exit: AgentWorkflowEdge, invocation: String) -> String {
        let target = definition.nodes.first { $0.id == exit.target }?.name ?? "the after-loop step"
        return """
        When this step's approval condition is met, use ctrlx workflow exit-loop --invocation \(invocation) --reason "<reason>" to continue to \(target). Then provide the final result for that step. Use this route for any approval instructions above that say to end the workflow. If approval conditions are not met, complete this step normally to continue the round.
        """
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
        guard definition.activeNodeIDs(round: round).contains(node.id) || definition.afterLoopNodeIDs.contains(node.id) else { return .init() }
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
