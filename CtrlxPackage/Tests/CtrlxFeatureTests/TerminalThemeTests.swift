#if os(iOS)
    import CtrlxCommon
    import Dependencies
    import SwiftUI
    import Testing
    import UIKit
    @testable import CtrlxFeature
    @testable import SwiftTerm

    @Suite("iOS terminal themes")
    @MainActor
    struct TerminalThemeTests {
        @Test("Terminal theme persists independently of app appearance")
        func preference() {
            withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: {
                let settings = IOSSettings()
                #expect(settings.terminalTheme == .defaultDark)
                settings.appearanceMode = .dark
                settings.terminalTheme = .codexLight
                let restored = IOSSettings()
                #expect(restored.terminalTheme == .codexLight)
                #expect(restored.appearanceMode == .dark)
            }
        }

        @Test("An unknown saved theme falls back to Default Dark")
        func unknownTheme() {
            withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: {
                @Dependency(PreferencesService.self) var preferences
                preferences.setString("removed-theme", IOSSettings.Keys.terminalTheme)
                #expect(IOSSettings().terminalTheme == .defaultDark)
            }
        }

        @Test("Live theme changes preserve terminal contents, selection and explicit RGB colors")
        func liveThemeChange() throws {
            let view = InteractiveTerminalView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), font: nil)
            view.applyTheme(.defaultDark)
            view.feedTerminalData(Array("\u{1B}[31mR\u{1B}[38;2;12;34;56mT\u{1B}[0m".utf8)[...])
            view.setSelectionRange(start: .init(col: 0, row: 0), end: .init(col: 2, row: 0))
            let selectedText = view.getSelection()
            #expect(selectedText == "RT")
            let terminal = view.getTerminal()
            let columns = terminal.cols
            let rows = terminal.rows

            for theme in [TerminalTheme.codexLight, .anysphereDark, .defaultLight, .defaultDark] {
                view.applyTheme(theme)
                #expect(view.getTerminal() === terminal)
                #expect(terminal.cols == columns && terminal.rows == rows)
                #expect(view.getSelection() == selectedText)
                #expect(view.nativeForegroundColor == theme.palette.foreground.nativeColor)
                #expect(view.nativeBackgroundColor == theme.palette.background.nativeColor)
                #expect(view.layer.backgroundColor == theme.palette.background.nativeColor.cgColor)
                #expect(view.caretColor == theme.palette.foreground.nativeColor)
                #expect(Array(terminal.ansiColors.prefix(16)) == theme.palette.swiftTermANSIColors)
                let line = try #require(terminal.getLine(row: 0))
                #expect(line[0].attribute.fg == .ansi256(code: 1))
                #expect(line[1].attribute.fg == .trueColor(red: 12, green: 34, blue: 56))
            }
        }

        @Test("The mounted container changes its terminal and all surrounding backgrounds in place")
        func containerThemeChange() async throws {
            let state = TerminalState(width: 30, height: 10, fontName: "Menlo", fontSize: 10)
            state.feed(Data("theme preview".utf8))
            let host = UIHostingController(rootView: Self.container(state: state, theme: .defaultDark))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()
            let terminal = try #require(Self.terminal(in: host.view))
            let canvas = try #require(terminal.superview)
            let scroll = try #require(canvas.superview as? UIScrollView)

            for theme in [TerminalTheme.codexLight, .defaultDark] {
                host.rootView = Self.container(state: state, theme: theme)
                try await Task.sleep(for: .milliseconds(50))
                host.view.layoutIfNeeded()
                #expect(Self.terminal(in: host.view) === terminal)
                #expect(terminal.nativeBackgroundColor == theme.palette.background.nativeColor)
                #expect(canvas.backgroundColor == theme.palette.background.nativeColor)
                #expect(scroll.backgroundColor == theme.palette.background.nativeColor)
                #expect(terminal.getTerminal().cols == 30 && terminal.getTerminal().rows == 10)
            }
        }

        static func container(state: TerminalState, theme: TerminalTheme) -> TerminalStreamContainerView {
            TerminalStreamContainerView(
                terminalState: state, theme: theme, scrollingAgentID: nil, codexQuestionID: nil,
                inputEnabled: false, keyboardRequested: false, onKeyboardRequest: nil,
                keyboardIsTransitioning: false, questionExpansionEnabled: false,
                onExpandCodexQuestions: { _, _ in false }, onInput: { _ in }, onRawInput: { _ in },
                onCompositionStart: { }, onPasteText: { _ in }, onPasteImage: nil,
                onViewportGridChange: { _ in }, onInitialPresentation: { }
            )
        }

        private static func terminal(in view: UIView) -> InteractiveTerminalView? {
            if let terminal = view as? InteractiveTerminalView {
                return terminal
            }
            return view.subviews.lazy.compactMap { terminal(in: $0) }.first
        }
    }
#endif
