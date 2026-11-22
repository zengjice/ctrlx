import CtrlxNetworking
import SwiftUI

@MainActor
struct AgentWorkflowAttachmentRows: View {
    let ids: [UUID]
    let attachments: [UUID: AgentWorkflowAttachment]
    let remove: (UUID) -> Void
    var thumbnails: [UUID: Data] = [:]
    @State private var preview: Preview?

    private struct Preview: Identifiable {
        let id: UUID
        let name: String
        let image: PhotoPreviewImage
    }

    var body: some View {
        ForEach(ids, id: \.self) { id in
            HStack {
                if let data = thumbnails[id] {
                    let name = attachments[id]?.name ?? "Image"
                    Button {
                        if let image = PhotoPreviewImage(data: data) {
                            preview = Preview(id: id, name: name, image: image)
                        }
                    } label: {
                        AgentWorkflowImageThumbnail(data: data).frame(width: 52, height: 52)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Preview \(name)")
                }
                AgentWorkflowAttachmentLabel(attachment: attachments[id])
                Spacer()
                Button("Remove", role: .destructive) { remove(id) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(attachments[id]?.name ?? "attachment")")
                    .accessibilityIdentifier("workflow-remove-attachment-\(id)")
            }
        }
        .sheet(item: $preview) { item in
            VStack(spacing: 8) {
                HStack {
                    Text(item.name).font(.headline).lineLimit(1)
                    Spacer()
                    Button("Done") { preview = nil }.keyboardShortcut(.cancelAction)
                }
                .padding()
                ZoomablePhotoPreview(image: item.image)
            }
            #if os(macOS)
            .frame(minWidth: 520, idealWidth: 680, minHeight: 430, idealHeight: 580)
            #endif
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
