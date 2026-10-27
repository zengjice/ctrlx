#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    struct LinkedTabSourceButton: View {
        let isAgentSource: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Label {
                    Text(isAgentSource ? "Go to Agent Tab" : "Go to Terminal Tab")
                } icon: {
                    (isAgentSource ? Symbols.sparkles : .terminal).image
                        .overlay(alignment: .topTrailing) {
                            Symbols.arrowLeft.image
                                .font(.system(size: 8, weight: .bold))
                                .offset(x: 4, y: -4)
                                .accessibilityHidden(true)
                        }
                }
            }
            .accessibilityIdentifier("linked-tab-return-source")
            .accessibilityHint("Return to the source tab without closing this tab")
        }
    }
#endif
