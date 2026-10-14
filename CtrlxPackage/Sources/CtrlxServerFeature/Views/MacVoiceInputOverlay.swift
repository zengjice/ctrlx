import CtrlxCommon
import SwiftUI

/// Attach above the status bar without changing the terminal's layout or responder.
@MainActor
struct MacVoiceInputOverlay: ViewModifier {
    let session: TerminalVoiceInputSession

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    if session.isPresented {
                        VoiceInputPreview(voice: session.voice, cancel: session.cancel)
                            .frame(maxWidth: 560)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 6)
                    }
                }
                // The conditional content does not propagate its explicit guide.
                .alignmentGuide(.top) { $0[.bottom] }
            }
            .background {
                // System permission prompts may deactivate the app during preparation.
                MacVoiceInputCancellation(
                    isActive: session.voice.phase == .recording || session.voice.phase == .finalizing,
                    onCancel: session.cancel
                )
            }
            .onDisappear(perform: session.cancel)
    }
}
