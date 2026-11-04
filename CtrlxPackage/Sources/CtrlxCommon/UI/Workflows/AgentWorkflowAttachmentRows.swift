import CtrlxNetworking
import SwiftUI

@MainActor
struct AgentWorkflowAttachmentRows: View {
    let ids: [UUID]
    let attachments: [UUID: AgentWorkflowAttachment]
    let remove: (UUID) -> Void
    var thumbnails: [UUID: Data] = [:]

    var body: some View {
        ForEach(ids, id: \.self) { id in
            HStack {
                if let data = thumbnails[id] {
                    AgentWorkflowImageThumbnail(data: data).frame(width: 52, height: 52)
                }
                AgentWorkflowAttachmentLabel(attachment: attachments[id])
                Spacer()
                Button("Remove", role: .destructive) { remove(id) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(attachments[id]?.name ?? "attachment")")
                    .accessibilityIdentifier("workflow-remove-attachment-\(id)")
            }
        }
    }
}

@MainActor
struct AgentWorkflowAttachmentLabel: View {
    let attachment: AgentWorkflowAttachment?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let attachment {
                Text(attachment.name)
                Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                if let conversion = attachment.conversion {
                    Text("From \(conversion.sourceName) · \(conversion.description)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !["image/png", "image/jpeg", "text/plain", "text/markdown"].contains(attachment.mediaType) {
                    Text("Needs conversion before running").font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Attachment information unavailable").foregroundStyle(.secondary)
            }
        }
    }
}
