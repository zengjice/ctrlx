#if os(macOS) || os(iOS)
    import SwiftUI

    /// Feedback must not resize a fitted remote surface or intercept its input.
    @MainActor
    struct WorkspaceClipboardFeedback: ViewModifier {
        let message: String?

        func body(content: Content) -> some View {
            content.overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
    }
#endif
