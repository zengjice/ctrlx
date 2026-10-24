import CtrlxNetworking
import SwiftUI

@MainActor
struct AgentWorkflowInputPreview: View {
    let definition: AgentWorkflowDefinition
    let node: AgentWorkflowNode
    let attachments: [UUID: AgentWorkflowAttachment]
    @State private var nextRound = false

    var body: some View {
        let input = AgentWorkflowPrompt.preview(definition: definition, node: node, round: nextRound ? 2 : 1)
        List {
            Section {
                if definition.loop != nil, node.id == definition.entryNodeID {
                    Toggle("Preview a later round", isOn: $nextRound)
                }
                Text(node.kind == .content
                    ? "This content is forwarded automatically. Upstream outputs are placeholders until execution; the saved output appears in the run's handoff history."
                    : "This shows the task format. Upstream outputs and the invocation ID are placeholders until execution; full outputs appear in the run's handoff history.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(node.kind == .content ? "Text forwarded to downstream nodes" : "Text sent to Agent") {
                Text(verbatim: input.text).font(.body.monospaced()).textSelection(.enabled)
            }
            Section("Attachments") {
                if input.attachmentIDs.isEmpty {
                    Text("No initial or preset attachments for this task.").foregroundStyle(.secondary)
                } else {
                    ForEach(input.attachmentIDs, id: \.self) { AgentWorkflowAttachmentLabel(attachment: attachments[$0]) }
                }
                if !definition.upstream(of: node.id).isEmpty || nextRound {
                    Text("Attachments from upstream content nodes and artifacts explicitly shared by upstream Agents are added after they complete.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("\(node.kind == .content ? "Output" : "Input") · \(node.name)")
    }
}
