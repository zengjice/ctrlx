#if os(macOS)
    import AppKit
    import CtrlxCommon
    import Dependencies
    import Testing
    @testable import CtrlxServerFeature
    @testable import SwiftTerm

    @Suite("Terminal theme palettes")
    struct TerminalThemePaletteTests {
        @Test("Every theme has a complete ANSI palette", arguments: TerminalTheme.allCases)
        func completeANSITheme(theme: TerminalTheme) {
            #expect(theme.palette.ansiColors.count == 16)
        }

        @Test("Codex Light keeps colored and gray ANSI text readable on white")
        func codexLightContrast() {
            let palette = TerminalTheme.codexLight.palette
            // White slots intentionally remain light for terminal backgrounds.
            for index in [0, 1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14] {
                let color = palette.ansiColors[index]
                #expect(contrast(color, palette.background) >= 4.5, "ANSI slot \(index)")
            }
            #expect(contrast(palette.foreground, palette.background) >= 15)
            #expect(TerminalTheme.codexLight.workspaceColorScheme == .light)
        }

        @MainActor
        @Test("Codex Light persists without changing the default for existing users")
        func codexLightPreference() {
            withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: {
                let settings = AppSettings()
                #expect(settings.theme == .defaultDark)
                settings.theme = .codexLight
                #expect(AppSettings().theme == .codexLight)
            }
        }

        @MainActor
        @Test("A mounted terminal switches palettes without changing Agent RGB output")
        func liveThemeSwitch() throws {
            let view = InteractiveTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            view.feed(byteArray: Array("\u{1B}[31mR\u{1B}[38;2;12;34;56mT\u{1B}[0m".utf8)[...])

            for theme in [TerminalTheme.defaultDark, .codexLight, .anysphereDark, .codexLight, .defaultLight] {
                view.applyTheme(theme)
                #expect(view.nativeForegroundColor == theme.palette.foreground.nativeColor)
                #expect(view.nativeBackgroundColor == theme.palette.background.nativeColor)
                let terminal = view.getTerminal()
                #expect(Array(terminal.ansiColors.prefix(16)) == theme.palette.swiftTermANSIColors)
                let line = try #require(terminal.getLine(row: 0))
                #expect(line[0].attribute.fg == .ansi256(code: 1))
                #expect(line[1].attribute.fg == .trueColor(red: 12, green: 34, blue: 56))
            }
        }

        private func contrast(_ foreground: TerminalRGB, _ background: TerminalRGB) -> Double {
            func luminance(_ color: TerminalRGB) -> Double {
                let components = [color.red, color.green, color.blue].map { component -> Double in
                    let value = Double(component) / 255
                    return value <= 0.04_045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                return components[0] * 0.2_126 + components[1] * 0.7_152 + components[2] * 0.0_722
            }
            let first = luminance(foreground)
            let second = luminance(background)
            return (max(first, second) + 0.05) / (min(first, second) + 0.05)
        }

        @Test("Anysphere Dark matches the Coterm palette")
        func anysphereDarkPalette() {
            let palette = TerminalTheme.anysphereDark.palette

            #expect(palette.foreground == TerminalRGB(hex: 0xF0F0F0))
            #expect(palette.background == TerminalRGB(hex: 0x141414))
            #expect(palette.ansiColors == TerminalThemePalette.anysphereDarkANSI)
            #expect(palette.ansiColors[1] == TerminalRGB(hex: 0xFC6B83))
            #expect(palette.ansiColors[10] == TerminalRGB(hex: 0x70B489))
        }

        @Test("Anysphere Dark keeps terminal and workspace surfaces separate")
        func anysphereDarkWorkspacePalette() {
            let terminal = TerminalTheme.anysphereDark.palette
            let workspace = TerminalTheme.anysphereDark.workspacePalette

            #expect(terminal.background == TerminalRGB(hex: 0x141414))
            #expect(workspace.sidebarBackground == .init(hex: 0x141414))
            #expect(workspace.workspaceBackground == .init(hex: 0x181818))
            #expect(workspace.chromeBackground == .init(hex: 0x202020, alpha: 0xCC))
            #expect(workspace.activeTabBackground == .init(hex: 0x181818))
            #expect(workspace.border == .init(hex: 0x303030))
            #expect(workspace.selectedSidebarRow == .init(hex: 0x1C1C1C))
        }

        @Test("Existing themes retain their terminal background", arguments: [
            TerminalTheme.defaultDark,
            TerminalTheme.defaultLight,
            TerminalTheme.solarizedDark,
            TerminalTheme.solarizedLight,
        ])
        func existingThemeWorkspaceBackground(theme: TerminalTheme) {
            #expect(theme.workspacePalette.workspaceBackground.color == theme.palette.background)
            #expect(theme.workspacePalette.workspaceBackground.alpha == 0xFF)
        }

        @Test("Default Dark uses the macOS dark window background")
        func defaultDarkBackground() {
            #expect(TerminalTheme.defaultDark.palette.background == TerminalRGB(hex: 0x1E1E1E))
        }

        @Test("OSC colors preserve full byte precision")
        func oscColors() {
            let palette = TerminalTheme.anysphereDark.palette

            #expect(palette.foreground.oscValue == "f0f0/f0f0/f0f0")
            #expect(palette.background.oscValue == "1414/1414/1414")
        }

        @Test("Anysphere Dark is exposed as a selectable theme")
        func selectableTheme() {
            #expect(TerminalTheme(rawValue: "Anysphere Dark") == .anysphereDark)
            #expect(TerminalTheme.allCases.contains(.anysphereDark))
        }

        @Test("Workbench contrast follows terminal theme brightness")
        func workbenchColorScheme() {
            #expect(TerminalTheme.defaultDark.workspaceColorScheme == .dark)
            #expect(TerminalTheme.solarizedDark.workspaceColorScheme == .dark)
            #expect(TerminalTheme.anysphereDark.workspaceColorScheme == .dark)
            #expect(TerminalTheme.defaultLight.workspaceColorScheme == .light)
            #expect(TerminalTheme.solarizedLight.workspaceColorScheme == .light)
        }
    }
#endif
