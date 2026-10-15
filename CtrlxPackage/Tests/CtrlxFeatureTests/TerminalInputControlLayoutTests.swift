#if os(iOS)
    import CtrlxCommon
    import SwiftUI
    import Testing
    @testable import CtrlxFeature

    @MainActor
    @Suite("Terminal first-row control layout")
    struct TerminalInputControlLayoutTests {
        @Test("Built-in labels share one width at standard and accessibility text sizes")
        func builtInWidths() throws {
            for textSize in [DynamicTypeSize.large, .accessibility3] {
                let expected = try size(of: Text("Send").terminalInputControlStyle(), textSize: textSize)
                if textSize == .large {
                    #expect(expected.width == TerminalInputControlMetrics.buttonWidth)
                } else {
                    #expect(expected.width > TerminalInputControlMetrics.buttonWidth)
                }

                for title in ["/", "←", "→", "⌫", "esc", "$", "Send"] {
                    let measured = try size(of: Text(title).terminalInputControlStyle(), textSize: textSize)
                    #expect(measured.width == expected.width)
                }
                for symbol in [Symbols.plus, .mic, .micFill, .textBubbleFill] {
                    let measured = try size(of: symbol.image.terminalInputControlStyle(), textSize: textSize)
                    #expect(measured.width == expected.width)
                }
            }
        }

        @Test("Voice and progress content cannot enlarge the shared control")
        func voiceStates() throws {
            for active in [false, true] {
                let voice = try size(of: Symbols.mic.image
                    .frame(width: 30, height: 30)
                    .terminalInputControlStyle(isActive: active))
                let progress = try size(of: ProgressView()
                    .controlSize(.small)
                    .frame(width: 30, height: 30)
                    .terminalInputControlStyle(isActive: active))
                #expect(voice.width == TerminalInputControlMetrics.buttonWidth)
                #expect(progress.width == voice.width)
                #expect(voice.height == TerminalInputControlMetrics.buttonHeight)
                #expect(progress.height == voice.height)
            }
        }

        @Test("Custom labels retain content-sized widths")
        func customWidth() throws {
            let short = try size(of: Text("X").frame(minWidth: 20)
                .terminalInputControlStyle(fixedWidth: false))
            let long = try size(of: Text("Review current changes").frame(minWidth: 20)
                .terminalInputControlStyle(fixedWidth: false))
            #expect(short.width == 40)
            #expect(long.width > TerminalInputControlMetrics.buttonWidth)
            #expect(long.width > short.width)
        }

        private func size(of content: some View, textSize: DynamicTypeSize = .large) throws -> CGSize {
            let renderer = ImageRenderer(content: content.environment(\.dynamicTypeSize, textSize))
            return try #require(renderer.uiImage).size
        }
    }
#endif
