import CtrlxCommon
import SwiftUI

struct TabReturnToMainButton: View {
    let tab: TabDragPayload
    let name: String
    @Environment(\.workbenchTabContext) private var context

    var body: some View {
        if let context, context.workspaceID != nil, tab.canDetach, let returnToMain = context.returnToMain {
            Button {
                returnToMain(context.drag(tab))
            } label: {
                Symbols.minus.image
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Return to Main Window")
            .accessibilityLabel("Return tab to main window: \(name)")
        }
    }
}
