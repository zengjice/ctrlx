#if os(macOS) || os(iOS)
    import CtrlxCommon
    import Testing
    @testable import CtrlxFeature

    @Suite("Codex light terminal color adaptation")
    struct CodexTerminalColorAdaptationTests {
        @Test("Reverse video preserves both sides of the original color pair")
        func inverseColors() {
            for theme in [TerminalTheme.codexLight, .defaultLight, .solarizedLight] {
                for hex: UInt32 in [0xD53538, 0x393939, 0xF2F2F2, 0xFFFFFF] {
                    for foreground in [false, true] {
                        let original = TerminalRGB(hex: hex)
                        #expect(CodexTerminalColorAdaptation.color(
                            original, foreground: foreground, inverse: true, palette: theme.palette
                        ) == original)
                    }
                }
            }
        }

        @Test("Host dark composer and history surfaces become light, including tinted diff blocks")
        func backgrounds() {
            for theme in [TerminalTheme.codexLight, .defaultLight, .solarizedLight] {
                for hex: UInt32 in [0x393939, 0x424242, 0x003010, 0x301010] {
                    let result = adapt(hex, foreground: false, theme: theme)
                    #expect(CodexTerminalColorAdaptation.luminance(result) > 0.65)
                }
            }
            #expect(adapt(0xF5F5F5, foreground: false) == TerminalRGB(hex: 0xF5F5F5))
        }

        @Test("Pastel text becomes readable on the adapted background while preserving hue")
        func foregrounds() {
            let background = adapt(0x393939, foreground: false)
            for hex: UInt32 in [0xB4DDB4, 0xD0D0FF, 0xDDCC99, 0xFFFFFF, 0x808080] {
                let text = adapt(hex, foreground: true)
                let ratio = (CodexTerminalColorAdaptation.luminance(background) + 0.05)
                    / (CodexTerminalColorAdaptation.luminance(text) + 0.05)
                #expect(ratio >= 4.5)
            }
            let green = adapt(0xB4DDB4, foreground: true)
            #expect(green.green > green.red && green.red == green.blue)
            #expect(adapt(0x0D0D0D, foreground: true) == TerminalRGB(hex: 0x0D0D0D))
        }

        @Test("Dark themes preserve explicit colors")
        func darkThemes() {
            for theme in [TerminalTheme.defaultDark, .solarizedDark, .anysphereDark] {
                for foreground in [false, true] {
                    #expect(adapt(0x393939, foreground: foreground, theme: theme) == TerminalRGB(hex: 0x393939))
                }
            }
        }

        private func adapt(_ hex: UInt32, foreground: Bool, theme: TerminalTheme = .codexLight) -> TerminalRGB {
            CodexTerminalColorAdaptation.color(.init(hex: hex), foreground: foreground, palette: theme.palette)
        }
    }
#endif
