import Foundation

public enum AgentWorkflowReviewTemplate {
    public static func apply(to definition: inout AgentWorkflowDefinition, developerID: UUID, reviewerID: UUID) {
        let develop = AgentWorkflowNode(name: "Initial development", agentInstanceID: developerID, initialTask: .textAndAttachments)
        let review = AgentWorkflowNode(
            name: "Review", agentInstanceID: reviewerID,
            input: .init(text: """
            Review the current implementation and tests in the shared working directory. Report concrete findings with severity, location and evidence.
            Do not modify files.

            Provide the findings for the Developer to judge.
            """), allowsFinish: true, initialTask: .omit
        )
        let judge = AgentWorkflowNode(
            name: "Judge findings", agentInstanceID: developerID,
            input: .init(text: """
            Evaluate the Reviewer's findings against the code and KISS. List Accepted and Rejected findings with reasons.
            Only judge the findings in this turn. Do not fix them yet.
            """), initialTask: .omit
        )
        let instructions = AgentWorkflowNode(name: "Repair instructions", content: .init(text: "Fix the Accepted findings from your preceding judgment. Run the relevant checks and report the results."), initialTask: .omit)
        let repair = AgentWorkflowNode(name: "Repair", agentInstanceID: developerID, initialTask: .omit)
        definition.participants = [
            .init(agentInstanceID: developerID, name: "Developer"),
            .init(agentInstanceID: reviewerID, name: "Reviewer"),
        ]
        definition.nodes = [develop, review, judge, instructions, repair]
        definition.edges = [
            .init(source: develop.id, target: review.id, includesResult: false),
            .init(source: review.id, target: judge.id),
            .init(source: judge.id, target: instructions.id, includesResult: false),
            .init(source: instructions.id, target: repair.id),
        ]
        definition.entryNodeID = develop.id
        definition.loop = .init(finalNodeID: repair.id, entryNodeID: review.id, includesResult: false)
    }
}
