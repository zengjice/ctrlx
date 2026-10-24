import SwiftUI

/// Compact control-ownership toggle shared by Browser and Simulator.
/// The lock state reflects whether this Viewer currently owns the surface.
struct RemoteControlButton: View {
    let title: String
    let isControlled: Bool
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, symbol: isControlled ? .lockFill : .lockOpenFill)
                .labelStyle(.iconOnly)
        }
        .disabled(isDisabled)
        .help(title)
    }
}
