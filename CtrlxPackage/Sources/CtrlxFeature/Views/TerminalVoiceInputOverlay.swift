#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    /// In-page preview, outside the terminal's size and responder ownership.
    @MainActor
    struct TerminalVoiceInputOverlay: ViewModifier {
        @Environment(\.scenePhase) private var scenePhase
        let session: TerminalVoiceInputSession
        let context: TerminalPhraseContext
        var isSuspended = false
        let insert: (String) -> Bool

        func body(content: Content) -> some View {
            content
                .overlay(alignment: .bottom) {
                    if session.isPresented {
                        VoiceInputPreview(
                            voice: session.voice, cancel: session.cancel,
                            stop: { session.toggle(in: context, snapshot: nil, selection: nil) }
                        )
                        .frame(maxWidth: 560)
                        .background(.regularMaterial, in: .rect(cornerRadius: 16))
                        .padding(12)
                    }
                }
                .onChange(of: context) { session.validate(in: context) }
                .onChange(of: isSuspended) {
                    if isSuspended {
                        session.cancel()
                    }
                }
                .onChange(of: scenePhase) {
                    if scenePhase != .active {
                        session.cancel()
                    }
                }
                .onChange(of: session.voice.completedTranscript) {
                    guard !isSuspended, scenePhase == .active else { session.cancel()
                        return
                    }
                    session.deliver(in: context, insert: insert)
                }
                .onDisappear(perform: session.cancel)
                .modifier(VoiceInputErrorAlert(voice: session.voice))
        }
    }
#endif
