import SwiftUI

/// Compact control-ownership toggle shared by Browser and Simulator.
/// The icon shows whether this Viewer is viewing or controlling the surface.
struct RemoteControlButton: View {
    let title: String
    let isControlled: Bool
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, symbol: isControlled ? .handTapFill : .eye)
                .labelStyle(.iconOnly)
        }
        .foregroundStyle(isControlled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .disabled(isDisabled)
        .help("\(isControlled ? "Controlling" : "Read Only") · \(title)")
        .accessibilityValue(isControlled ? "Controlling" : "Read Only")
    }
}
