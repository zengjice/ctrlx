import SwiftUI

@MainActor
struct AgentWorkflowAuthorizationSheet: View {
    let canSubmit: Bool
    let cancel: () -> Void
    let confirm: (Date) -> Void
    @State private var expiresAt = Date().addingTimeInterval(86_400)

    var body: some View {
        NavigationStack {
            Form {
                Text("Authorize this workflow to continue sending tasks until the selected time. Completed results and the current round are kept.")
                DatePicker("Authorization expires", selection: $expiresAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            }
            .navigationTitle("Renew workflow authorization")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel).accessibilityIdentifier("workflow-cancel-renewal")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Authorize and continue") { confirm(expiresAt) }
                        .disabled(!canSubmit || expiresAt <= Date())
                        .accessibilityIdentifier("workflow-confirm-renewal")
                }
            }
        }
        .frame(idealWidth: 440, minHeight: 200)
    }
}
