import CtrlxNetworking
import Foundation
import Testing

struct AgentWorkflowPromptTests {
    private func definition() -> AgentWorkflowDefinition {
        let nodes = ["Developer", "Review A", "Review B", "Summary"].map {
            AgentWorkflowNode(name: $0, agentInstanceID: UUID(), input: .init(text: "$review-changes\nKeep the skill and these instructions."), allowsFinish: $0 == "Summary")
        }
        return .init(
            name: "Review", hostID: UUID(), nodes: nodes,
            edges: [
                .init(source: nodes[0].id, target: nodes[1].id),
                .init(source: nodes[0].id, target: nodes[2].id),
                .init(source: nodes[2].id, target: nodes[3].id),
                .init(source: nodes[1].id, target: nodes[3].id),
            ],
            entryNodeID: nodes[0].id, initialInput: .init(text: "Fix this issue."), loop: .init(finalNodeID: nodes[3].id)
        )
    }

    @Test
    func executionTextKeepsExactSkillAndCompleteAnswers() {
        let definition = definition()
        let longAnswer = String(repeating: "中文🙂\n", count: 20_000)
        let input = AgentWorkflowPrompt.compose(
            definition: definition, node: definition.nodes[3],
            answers: [.init(role: "Review A", round: 2, text: longAnswer), .init(role: "Review B", round: 2, text: "B's final answer.")],
            invocationReference: "invocation-1"
        )
        #expect(input.text == """
        $review-changes
        Keep the skill and these instructions.

        Initial task:
        Fix this issue.

        Answer from Review A (round 2):
        \(longAnswer)

        Answer from Review B (round 2):
        B's final answer.

        [CtrlX workflow invocation: invocation-1]
        May end workflow: ctrlx workflow finish --invocation invocation-1 --reason "<reason>"
        """)
    }

    @Test
    func previewsUseNodeOrderAndShowOnlyDirectOrPreviousRoundInputs() throws {
        let definition = definition()
        let summary = AgentWorkflowPrompt.preview(definition: definition, node: definition.nodes[3], round: 1).text
        #expect(try #require(summary.range(of: "Answer from Review A")).lowerBound < #require(summary.range(of: "Answer from Review B")).lowerBound)
        #expect(!summary.contains("Answer from Developer"))
        #expect(summary.contains("<Full output and attachments"))
        #expect(summary.contains("<assigned when this task is created>"))
        let first = AgentWorkflowPrompt.preview(definition: definition, node: definition.nodes[0], round: 1).text
        let second = AgentWorkflowPrompt.preview(definition: definition, node: definition.nodes[0], round: 2).text
        #expect(!first.contains("Answer from"))
        #expect(second.contains("Answer from Summary (round 1):"))
        #expect(!second.contains("Answer from Review A"))
        #expect(!first.contains("workflow finish"))
        #expect(!first.contains("workflow share"))
        #expect(!first.contains("workflow attachments"))
    }

    @Test
    func onlyEntryReceivesInitialAttachmentsAndSourcesRemainScoped() {
        var definition = definition()
        let initial = UUID(), preset = UUID(), result = UUID()
        definition.initialInput.attachmentIDs = [initial]
        definition.nodes[0].input.attachmentIDs = [preset, initial]
        definition.nodes[3].input.attachmentIDs = [preset]
        let answers: [AgentWorkflowPrompt.Answer] = [.init(role: "Reviewer", round: 1, text: "Done", attachmentIDs: [result, preset])]
        let entry = AgentWorkflowPrompt.compose(definition: definition, node: definition.nodes[0], answers: answers, invocationReference: "id")
        let summary = AgentWorkflowPrompt.compose(definition: definition, node: definition.nodes[3], answers: answers, invocationReference: "id")
        #expect(entry.attachmentIDs == [preset, initial, result])
        #expect(summary.attachmentIDs == [preset, result])
        #expect(!entry.text.contains("ctrlx workflow attachments"))
        #expect(!summary.text.contains("ctrlx workflow attachments"))
    }

    @Test
    func oldInFlightImageCallsKeepTheirOriginalReceiptTextAfterDecoding() throws {
        let input = AgentWorkflowInput(text: "Legacy task\n[CtrlX workflow invocation: id]", attachmentIDs: [UUID()])
        let invocationID = UUID()
        let delivery = AgentWorkflowDelivery(runID: UUID(), round: 1, invocationID: invocationID, toAgentID: UUID(), sources: [], input: input)
        var invocation = AgentWorkflowInvocation(id: invocationID, nodeID: UUID(), round: 1, delivery: delivery, createdAt: Date())
        let legacy = try JSONDecoder().decode(AgentWorkflowInvocation.self, from: JSONEncoder().encode(invocation))
        #expect(legacy.submissionText(pluginID: "codex") == input.text)
        invocation.nativeImageNumbers = [3]
        let native = try JSONDecoder().decode(AgentWorkflowInvocation.self, from: JSONEncoder().encode(invocation))
        #expect(native.submissionText(pluginID: "codex") == "[Image #3] " + input.text)
    }

    @Test(arguments: ["codex", "claude-code"])
    func nativeImagesHaveExactProviderReceiptText(plugin: String) {
        let text = "$skill\nTask\n[CtrlX workflow invocation: exact-id]"
        let input = AgentWorkflowInput(text: text, attachmentIDs: [UUID(), UUID()])
        #expect(AgentWorkflowPrompt.submittedText(input, pluginID: plugin, imageNumbers: [3, 5]) == "[Image #3] [Image #5]" + (plugin == "codex" ? " " : "") + text)
        #expect(AgentWorkflowPrompt.submittedText(.init(text: text), pluginID: plugin, imageNumbers: []) == text)
    }

    @Test
    func contentCombinesExactMaterialWithoutInjectingAgentCommands() {
        let initial = UUID(), preset = UUID(), shared = UUID()
        let node = AgentWorkflowNode(name: "Brief", content: .init(text: "$review-changes\nKeep this exact.\n", attachmentIDs: [preset]))
        let definition = AgentWorkflowDefinition(
            name: "Content",
            hostID: UUID(),
            nodes: [node],
            edges: [],
            entryNodeID: node.id,
            initialInput: .init(text: "Original task", attachmentIDs: [initial])
        )
        let input = AgentWorkflowPrompt.compose(
            definition: definition,
            node: node,
            answers: [.init(role: "Review", round: 1, text: "中文🙂\nFull answer", attachmentIDs: [shared, preset])],
            invocationReference: "must-not-be-injected"
        )
        #expect(input.text == "$review-changes\nKeep this exact.\n\n\nInitial task:\nOriginal task\n\nOutput from Review (round 1):\n中文🙂\nFull answer")
        #expect(input.attachmentIDs == [preset, initial, shared])
        #expect(!input.text.contains("ctrlx workflow"))
        #expect(!input.text.contains("must-not-be-injected"))
        let preview = AgentWorkflowPrompt.preview(definition: definition, node: node, round: 1)
        #expect(preview.attachmentIDs == [preset, initial])
        #expect(!preview.text.contains("assigned when"))
    }
}
