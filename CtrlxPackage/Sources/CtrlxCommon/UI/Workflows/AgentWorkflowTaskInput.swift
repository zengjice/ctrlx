import CtrlxNetworking
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AgentWorkflowTaskInput: View {
    let title: String
    @Binding var text: String
    let ids: [UUID]
    let attachments: [UUID: AgentWorkflowAttachment]
    let add: () -> Void
    let photos: (() -> Void)?
    let receive: ([AgentWorkflowImageSource]) -> Void
    let remove: (UUID) -> Void
    let progress: (name: String, value: Double)?
    let error: String?
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentWorkflowTextInput(title: title, text: $text, receive: receive)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(title).foregroundStyle(.tertiary).padding(.top, 8).allowsHitTesting(false)
                    }
                }
            AgentWorkflowAttachmentRows(ids: ids, attachments: attachments, remove: remove)
            HStack(spacing: 16) {
                if let photos {
                    Menu {
                        Button("Photo Library", action: photos)
                        Button("Choose image files…", action: add)
                    } label: { Label("Add images", symbol: .photoBadgePlus) }
                } else {
                    Button(action: add) { Label("Add images", symbol: .photoBadgePlus) }
                }
                PasteButton(supportedContentTypes: AgentWorkflowImageSource.contentTypes) {
                    receiveProviders($0)
                }
                .labelStyle(.titleOnly)
            }
            .buttonStyle(.borderless)
            Text("Paste or drop images here. Reference other files by their workspace paths.")
                .font(.caption).foregroundStyle(.secondary)
            if let progress {
                Text(progress.name).font(.caption)
                ProgressView(value: progress.value)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onDrop(of: AgentWorkflowImageSource.contentTypes, isTargeted: $targeted) { providers in
            guard !providers.isEmpty else { return false }
            receiveProviders(providers)
            return true
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 2).allowsHitTesting(false)
            }
        }
    }

    private func receiveProviders(_ providers: [NSItemProvider]) {
        let images = providers.filter { provider in
            AgentWorkflowImageSource.contentTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }
        if !images.isEmpty {
            receive(images.map(AgentWorkflowImageSource.provider))
        }
    }
}
