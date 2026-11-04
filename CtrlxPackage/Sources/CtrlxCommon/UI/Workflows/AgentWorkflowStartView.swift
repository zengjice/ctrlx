import CtrlxNetworking
import os
import SwiftUI

@MainActor
struct AgentWorkflowStartView: View {
    let endpoint: AgentWorkflowEndpoint
    let hostID: UUID
    let definitionID: UUID
    let navigation: AgentWorkflowNavigation
    @Environment(\.dismiss) private var dismiss
    @State private var definition: AgentWorkflowDefinition?
    @State private var input = AgentWorkflowInput()
    @State private var attachments: [UUID: AgentWorkflowAttachment] = [:]
    @State private var importedIDs: Set<UUID> = []
    @State private var importing = false
    @State private var activeImport: AgentWorkflowImageImport?
    @State private var busy = false
    @State private var expiresAt = Date().addingTimeInterval(86_400)
    @State private var pendingStart: ManageAgentWorkflows.Operation?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let definition {
                    Section {
                        AgentWorkflowImageInput(
                            endpoint: endpoint,
                            hostID: hostID,
                            title: "Task for this run",
                            text: $input.text,
                            ids: $input.attachmentIDs,
                            attachments: $attachments,
                            importedIDs: $importedIDs,
                            importing: $importing, activeImport: $activeImport,
                            totalImageCount: Set(definition.nodes.flatMap { $0.input.attachmentIDs }).union(input.attachmentIDs).count
                        )
                        .disabled(busy || pendingStart != nil)
                    } header: { Text("Initial task") } footer: { Text("Used for this run. The saved configuration stays available for the next task.") }
                    Section {
                        Text("\(definition.name) · \(definition.nodes.count) steps")
                        DisclosureGroup("Run options") {
                            DatePicker("Authorization expires", selection: $expiresAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                                .disabled(busy || pendingStart != nil)
                        }
                        if pendingStart != nil {
                            Text("The start has not been confirmed. Retry checks the same task and request; you can also check Runs.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if error == nil {
                    ProgressView("Loading task…")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Start workflow")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(pendingStart == nil ? "Start" : "Retry") {
                        if let definition {
                            start(definition)
                        }
                    }
                    .disabled(definition == nil || busy || importing || !endpoint.isConnected)
                    .accessibilityIdentifier("workflow-start-confirm")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(importing ? "Stop upload" : "Close") {
                        if importing {
                            if activeImport == nil {
                                importing = false
                            }
                            activeImport = nil
                        } else {
                            close()
                        }
                    }.disabled(busy)
                        .accessibilityIdentifier("workflow-start-close")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 600, minHeight: 400, idealHeight: 560)
        #endif
        .interactiveDismissDisabled(busy || importing || !importedIDs.isEmpty || pendingStart != nil)
        .task(id: activeImport?.id) {
            guard let activeImport else { return }
            await activeImport.perform()
        }
        .task {
            do {
                let response = try await endpoint.request(.definition(definitionID), hostID: hostID)
                guard let value = response.definition else { throw AgentWorkflowError("The configuration is unavailable.") }
                let metadata = try await endpoint.attachments(Array(value.attachmentIDs), hostID: hostID)
                try Task.checkCancellation()
                definition = value
                input = value.initialInput
                attachments = Dictionary(uniqueKeysWithValues: metadata.map { ($0.id, $0) })
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func start(_ definition: AgentWorkflowDefinition) {
        guard !busy, !importing else { return }
        let attempt = pendingStart ?? .start(
            definitionID: definition.id,
            expectedRevision: definition.revision,
            requestID: UUID(),
            authorizationExpiresAt: expiresAt,
            initialInput: input
        )
        pendingStart = attempt
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await navigation.startRun(attempt, endpoint: endpoint, hostID: hostID, configurationID: definition.id)
                pendingStart = nil
                // Run-owned images are retained; remove only discarded draft images.
                await discard(importedIDs.subtracting(Set(input.attachmentIDs)))
                importedIDs.removeAll()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func close() {
        busy = true
        Task {
            // An unconfirmed start may already own the images on the Host.
            if pendingStart == nil {
                await discard(importedIDs)
            }
            importedIDs.removeAll()
            busy = false
            dismiss()
        }
    }

    private func discard(_ ids: Set<UUID>) async {
        let values = Array(ids)
        for offset in stride(from: 0, to: values.count, by: AgentWorkflowWire.maximumAttachments) {
            let end = min(values.count, offset + AgentWorkflowWire.maximumAttachments)
            do { _ = try await endpoint.request(.discardAttachments(Array(values[offset..<end])), hostID: hostID) }
            catch { Logger(subsystem: "com.jicezeng.ctrlx", category: "WorkflowUploads").debug("Could not discard draft images: \(error.localizedDescription)") }
        }
    }
}
