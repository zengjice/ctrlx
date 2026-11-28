import Foundation
import Testing
@testable import CtrlxNetworking

struct AgentWorkflowStepsTests {
    private func sample() -> AgentWorkflowDefinition {
        var definition = AgentWorkflowDefinition(name: "Develop and review", hostID: UUID(), nodes: [], edges: [], entryNodeID: UUID(), initialInput: .init(text: "Implement the original task", attachmentIDs: [UUID()]))
        AgentWorkflowReviewTemplate.apply(to: &definition, developerID: UUID(), reviewerID: UUID())
        return definition
    }

    @Test
    func oldNodesDefaultToReplyCompletionAndNewPromptsDescribeOnlySelectedMode() throws {
        let definition = sample()
        var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(definition.nodes[0])) as? [String: Any])
        raw.removeValue(forKey: "completion")
        let old = try JSONDecoder().decode(AgentWorkflowNode.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(old.completion == .replyEnded)
        for node in definition.nodes {
            let prompt = AgentWorkflowPrompt.preview(definition: definition, node: node, round: 1).text
            #expect(prompt.contains("ctrlx workflow complete-step") == (node.completion == .explicit))
        }
    }

    @Test
    func templateUsesTwoParticipantsAndRepeatsOnlyTheReviewRepairSection() throws {
        let definition = sample()
        try definition.validate()
        #expect(definition.nodes.map(\.name) == ["Initial development", "Review", "Judge findings", "Repair instructions", "Repair", "Commit", "Merge"])
        #expect(definition.nodes.map(\.completion) == [.explicit, .replyEnded, .explicit, .replyEnded, .explicit, .replyEnded, .replyEnded])
        #expect(definition.agents.map(\.name) == ["Developer", "Reviewer"])
        #expect(definition.agentInstanceIDs.count == 2)
        #expect(definition.nodes.filter { $0.agentInstanceID == definition.agents[0].id }.count == 5)
        #expect(definition.activeNodeIDs(round: 1).count == 5)
        #expect(definition.activeNodeIDs(round: 2) == Set(definition.nodes[1...4].map(\.id)))
        #expect(definition.entryNodeID(round: 2) == definition.nodes[1].id)
        #expect(definition.loop?.includesResult == false)
        #expect(definition.loop?.maximumRounds == 100)
        #expect(definition.loop?.finalNodeID == definition.nodes[4].id)
        #expect(definition.loopExit == .init(source: definition.nodes[1].id, target: definition.nodes[5].id))
        #expect(definition.afterLoopNodeIDs == Set(definition.nodes[5...6].map(\.id)))
        #expect(definition.upstream(of: definition.nodes[6].id).map(\.id) == [definition.nodes[5].id])
        #expect(try JSONDecoder().decode(AgentWorkflowDefinition.self, from: JSONEncoder().encode(definition)) == definition)
    }

    @Test
    func templateApprovalPromptsLeadToCommitAndMergeWithPortableSkillInstructions() {
        let definition = sample()
        let review = AgentWorkflowPrompt.preview(definition: definition, node: definition.nodes[1], round: 1).text
        #expect(review.contains("review-changes skill when available"))
        #expect(review.contains("no P2 or higher-priority findings"))
        #expect(review.contains("ctrlx workflow exit-loop") && review.contains("continue to Commit"))
        #expect(!review.contains("ctrlx workflow finish"))
        #expect(definition.nodes[2].input.text.contains("triage-review-findings skill when available"))
        #expect(definition.nodes[3].input.text.contains("fix-accepted-findings skill when available"))
        let commit = AgentWorkflowPrompt.preview(definition: definition, node: definition.nodes[5], round: 1).text
        #expect(commit.contains("Answer from Review") && !commit.contains("Initial task:"))
        let merge = AgentWorkflowPrompt.preview(definition: definition, node: definition.nodes[6], round: 1).text
        #expect(merge.contains("Answer from Commit") && !merge.contains("Initial task:"))
        #expect(merge.contains("primary working tree") && merge.contains("linked worktree") && merge.contains("merge main"))
    }

    @Test(arguments: [
        "使用 $review-changes 审查当前工作区。直至没有P3及以上问题项就退出workflow。",
        "使用 $review-changes 审查当前工作区，评审报告保存为review.md，直至没有P3及以上问题项就退出workflow。",
    ])
    func reviewTaskKeepsReportAndCompletionInstructionsTogether(_ task: String) throws {
        var definition = sample()
        definition.nodes[1].input.text = task
        let saved = try JSONDecoder().decode(AgentWorkflowDefinition.self, from: JSONEncoder().encode(definition))
        #expect(saved.nodes[1].input.text == task)
        for round in [1, 2] {
            for node in saved.nodes {
                let input = AgentWorkflowPrompt.preview(definition: saved, node: node, round: round)
                #expect(input.text.contains(task) == (node.id == saved.nodes[1].id))
            }
        }
    }

    @Test
    func completionOnlyInputsDoNotLeakAnswersImagesOrOriginalTask() {
        let definition = sample()
        let initial = AgentWorkflowPrompt.preview(definition: definition, node: definition.nodes[0], round: 1)
        #expect(initial.text.contains(definition.initialInput.text))
        #expect(initial.attachmentIDs == definition.initialInput.attachmentIDs)
        for round in [1, 2] {
            let review = AgentWorkflowPrompt.preview(definition: definition, node: definition.nodes[1], round: round)
            #expect(review.text.contains("Review the current implementation"))
            #expect(!review.text.contains("Initial task:") && !review.text.contains("Answer from") && !review.text.contains("Content from"))
            #expect(review.attachmentIDs.isEmpty)
        }
        let judge = AgentWorkflowPrompt.preview(definition: definition, node: definition.nodes[2], round: 1)
        #expect(judge.text.contains("Answer from Review (round 1)"))
        #expect(!judge.text.contains("Initial task:"))
        let content = AgentWorkflowPrompt.preview(definition: definition, node: definition.nodes[3], round: 1)
        #expect(content.text == definition.nodes[3].input.text)
        #expect(content.attachmentIDs.isEmpty)
        let repair = AgentWorkflowPrompt.preview(definition: definition, node: definition.nodes[4], round: 1)
        #expect(repair.text.contains("Content from Repair instructions"))
        #expect(!repair.text.contains("Initial task:"))
    }

    @Test(arguments: ["parallel-agent", "duplicate-participant", "unknown-participant", "unknown-loop-entry", "external-loop-dependency", "duplicate-edge-mode"])
    func invalidStepConfigurationsFailBeforeAnyTerminalInput(scenario: String) {
        var definition = sample()
        let nodes = definition.nodes
        switch scenario {
        case "parallel-agent": definition.edges.removeAll { $0.source == nodes[2].id && $0.target == nodes[3].id }
            definition.edges.append(.init(source: nodes[1].id, target: nodes[3].id))
        case "duplicate-participant":
            let participant = definition.agents[0]
            definition.participants?.append(participant)
        case "unknown-participant": definition.nodes[2].agentInstanceID = UUID()
        case "unknown-loop-entry": definition.loop?.entryNodeID = UUID()
        case "external-loop-dependency": definition.edges.append(.init(source: nodes[0].id, target: nodes[4].id))
        default: definition.edges.append(.init(source: nodes[0].id, target: nodes[1].id, includesResult: true))
        }
        #expect(throws: AgentWorkflowError.self) { try definition.validate() }
    }

    @Test
    func legacyConfigurationsKeepTheirOriginalInputAndLoopPolicies() throws {
        let a = AgentWorkflowNode(name: "A", agentInstanceID: UUID()), b = AgentWorkflowNode(name: "B", agentInstanceID: UUID())
        let definition = AgentWorkflowDefinition(name: "Legacy", hostID: UUID(), nodes: [a, b], edges: [.init(source: a.id, target: b.id)], entryNodeID: a.id, initialInput: .init(text: "Initial", attachmentIDs: [UUID()]), loop: .init(finalNodeID: b.id))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as? [String: Any])
        var edges = try #require(json["edges"] as? [[String: Any]])
        edges[0].removeValue(forKey: "includesResult")
        json["edges"] = edges
        var loop = try #require(json["loop"] as? [String: Any])
        loop.removeValue(forKey: "includesResult")
        json["loop"] = loop
        let old = try JSONDecoder().decode(AgentWorkflowDefinition.self, from: JSONSerialization.data(withJSONObject: json))
        try old.validate()
        #expect(!old.usesSteps && old.participants == nil)
        #expect(old.initialTask(for: a) == .textAndAttachments && old.initialTask(for: b) == .text)
        #expect(old.entryNodeID(round: 2) == a.id && old.loop?.includesResult == true && old.edges[0].includesResult)
        #expect(AgentWorkflowPrompt.preview(definition: old, node: b, round: 1).attachmentIDs.isEmpty)
        #expect(AgentWorkflowPrompt.preview(definition: old, node: a, round: 2).text.contains("Answer from B"))
    }
}
