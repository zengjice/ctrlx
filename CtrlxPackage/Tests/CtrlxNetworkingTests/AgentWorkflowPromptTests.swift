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

        To hand off a file, save it and run: ctrlx workflow share --invocation invocation-1 --file <local-file> --json. Share each required artifact before your final answer. This snapshots the file for downstream tasks; mentioning a path alone does not share it. If sharing fails, report the error rather than claiming delivery.

        You may end this workflow by running: ctrlx workflow finish --invocation invocation-1 --reason "your conclusion". Then provide your final answer.

        [CtrlX workflow invocation: invocation-1]
        """)
    }

    @Test
    func previewsUseNodeOrderAndShowOnlyDirectOrPreviousRoundInputs() throws {
        let definition = definition()
        let summary = AgentWorkflowPrompt.preview(definition: definition, node: definition.nodes[3], round: 1).text
        #expect(try #require(summary.range(of: "Answer from Review A")).lowerBound < #require(summary.range(of: "Answer from Review B")).lowerBound)
        #expect(!summary.contains("Answer from Developer"))
        #expect(summary.contains("<Full final answer"))
        #expect(summary.contains("<assigned when this task is created>"))
        let first = AgentWorkflowPrompt.preview(definition: definition, node: definition.nodes[0], round: 1).text
        let second = AgentWorkflowPrompt.preview(definition: definition, node: definition.nodes[0], round: 2).text
        #expect(!first.contains("Answer from"))
        #expect(second.contains("Answer from Summary (round 1):"))
        #expect(!second.contains("Answer from Review A"))
        #expect(!first.contains("workflow finish"))
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
    }
}
