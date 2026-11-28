import Foundation

public enum AgentWorkflowReviewTemplate {
    public static func apply(to definition: inout AgentWorkflowDefinition, developerID: UUID, reviewerID: UUID) {
        let develop = AgentWorkflowNode(name: "Initial development", agentInstanceID: developerID, initialTask: .textAndAttachments, completion: .explicit)
        let review = AgentWorkflowNode(
            name: "Review", agentInstanceID: reviewerID,
            input: .init(text: """
            Use the review-changes skill when available.
            Review the current implementation and tests in the shared working directory. Report concrete findings with severity, location and evidence.
            Do not modify files.

            When no P2 or higher-priority findings remain, approve the loop exit using the provided command to continue to Commit. Otherwise provide the findings for the Developer to judge.
            """), allowsFinish: true, initialTask: .omit
        )
        let judge = AgentWorkflowNode(
            name: "Judge findings", agentInstanceID: developerID,
            input: .init(text: """
            Use the triage-review-findings skill when available.
            Evaluate the Reviewer's findings against the code and KISS. List Accepted and Rejected findings with reasons.
            Only judge the findings in this turn. Do not fix them yet.
            """), initialTask: .omit, completion: .explicit
        )
        let instructions = AgentWorkflowNode(name: "Repair instructions", content: .init(text: """
        Use the fix-accepted-findings skill when available.
        Fix the Accepted findings from your preceding judgment, following KISS. Run the relevant checks and report the results.
        """), initialTask: .omit)
        let repair = AgentWorkflowNode(name: "Repair", agentInstanceID: developerID, initialTask: .omit, completion: .explicit)
        let commit = AgentWorkflowNode(name: "Commit", agentInstanceID: developerID, input: .init(text: "Commit the reviewed changes using a Conventional Commit. Report the commit and verification results."), initialTask: .omit)
        let merge = AgentWorkflowNode(name: "Merge", agentInstanceID: developerID, input: .init(text: """
        If you are in the primary working tree, merge the commits from each other worktree's branch into the current branch separately.
        If you are in a linked worktree, merge main into your current branch.
        Preserve uncommitted changes and report the result.
        """), initialTask: .omit)
        definition.participants = [
            .init(agentInstanceID: developerID, name: "Developer"),
            .init(agentInstanceID: reviewerID, name: "Reviewer"),
        ]
        definition.nodes = [develop, review, judge, instructions, repair, commit, merge]
        definition.edges = [
            .init(source: develop.id, target: review.id, includesResult: false),
            .init(source: review.id, target: judge.id),
            .init(source: judge.id, target: instructions.id, includesResult: false),
            .init(source: instructions.id, target: repair.id),
            .init(source: review.id, target: commit.id),
            .init(source: commit.id, target: merge.id),
        ]
        definition.entryNodeID = develop.id
        definition.loop = .init(finalNodeID: repair.id, maximumRounds: 100, entryNodeID: review.id, includesResult: false, exitNodeID: commit.id)
    }
}
