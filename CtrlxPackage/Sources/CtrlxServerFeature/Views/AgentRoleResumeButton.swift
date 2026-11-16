import SwiftUI

@MainActor
struct AgentRoleResumeButton: View {
    let tabClosed: Bool
    let action: () -> Void
    @State private var confirmsResume = false

    var body: some View {
        Button(tabClosed ? "Restore Original Conversation" : "Resume Original Conversation") {
            if tabClosed {
                action()
            } else {
                confirmsResume = true
            }
        }
        .confirmationDialog("Resume the saved conversation in this tab?", isPresented: $confirmsResume) {
            Button("Resume Original Conversation", action: action)
        } message: {
            Text("The idle shell will be restarted. Any unsubmitted shell input will be discarded. Running programs will be kept.")
        }
    }
}
