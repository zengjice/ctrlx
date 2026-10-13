import CtrlxCommon
import SwiftUI

struct TerminalFitButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Symbols.arrowUpLeftAndArrowDownRight.image
        }
        // Keep an explicit label: macOS may otherwise label this button by its symbol.
        .accessibilityLabel("Resize visible terminals to fit this Mac")
        .help("Resize visible terminals to fit this window; affects the Host and all Viewers")
    }
}
