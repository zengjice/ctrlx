#if os(macOS)
    import AppKit
    import CtrlxCommon
    import Testing
    @testable import CtrlxServerFeature
    @testable import SwiftTerm

    @Suite("Mac terminal light color adaptation", .serialized)
    @MainActor
    struct MacTerminalThemeTests {
        @Test("RGB and indexed composer colors become readable without changing terminal data", arguments: ["48;2;57;57;57", "48;5;237"])
        func explicitColors(backgroundSGR: String) throws {
            let view = makeView()
            view.scrollingAgentID = "codex"
            view.applyTheme(.defaultDark)
            view.feed(byteArray: Array("\u{1B}[\(backgroundSGR);38;2;180;221;180mText\u{1B}[0m".utf8)[...])
            let terminal = view.getTerminal()
            let line = try #require(terminal.getLine(row: 0))
            let attribute = line[0].attribute
            let columns = terminal.cols, rows = terminal.rows
            view.terminalView.selection.setSelection(start: .init(col: 0, row: 0), end: .init(col: 4, row: 0))
            let dark = try colors(view, attribute)

            for theme in [TerminalTheme.codexLight, .defaultLight, .solarizedLight] {
                view.applyTheme(theme)
                let light = try colors(view, attribute)
                #expect(CodexTerminalColorAdaptation.luminance(light.background) > 0.65)
                #expect(contrast(light.foreground, light.background) >= 4.5)
                #expect(light.foreground.green > light.foreground.red)
                #expect(view.getTerminal() === terminal)
                #expect(terminal.cols == columns && terminal.rows == rows)
                #expect(view.terminalView.getSelection() == "Text")
                #expect(line[0].attribute == attribute)

                view.scrollingAgentID = "claude-code"
                let reference = makeView()
                reference.applyTheme(theme)
                #expect(try colors(view, attribute) == colors(reference, attribute))
                view.scrollingAgentID = "codex"
                #expect(try colors(view, attribute) == light)
                view.applyTheme(.defaultDark)
                #expect(try colors(view, attribute) == dark)
            }
        }

        @Test("Inverse ANSI and RGB pairs retain their original contrast", arguments: [
            "7", "31;7", "1;31;7", "2;31;7", "38;2;213;53;56;7", "48;2;57;57;57;7",
            "38;2;242;242;242;48;2;57;57;57;7;4;58;2;213;53;56",
        ])
        func inverseColors(sgr: String) throws {
            let view = makeView()
            view.feed(byteArray: Array("\u{1B}[\(sgr)mInverse\u{1B}[0m".utf8)[...])
            let line = try #require(view.getTerminal().getLine(row: 0))
            let attribute = line[0].attribute
            for theme in [TerminalTheme.codexLight, .defaultLight, .solarizedLight, .defaultDark] {
                view.scrollingAgentID = nil
                view.applyTheme(theme)
                let baseline = try #require(view.terminalView.getAttributes(attribute, withUrl: false))
                view.scrollingAgentID = "codex"
                let adapted = try #require(view.terminalView.getAttributes(attribute, withUrl: false))
                for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineColor] {
                    #expect(adapted[key] as? NSColor == baseline[key] as? NSColor)
                }
                #expect(line[0].attribute == attribute)
                if sgr == "31;7", theme == .codexLight {
                    let pair = try colors(view, attribute)
                    #expect(contrast(pair.foreground, pair.background) > 4.2)
                }
            }
        }

        @Test("An already painted dark composer redraws when Codex metadata arrives and the theme changes")
        func composerRendering() async throws {
            let view = makeView()
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            view.applyTheme(.codexLight)
            view.feed(byteArray: Array("\u{1B}[?25l\u{1B}[48;2;57;57;57;38;2;180;221;180m  Ask Codex to do anything                    \u{1B}[0m\r\n".utf8)[...])
            view.layoutSubtreeIfNeeded()
            let attribute = try #require(view.getTerminal().getLine(row: 0))[0].attribute
            let dark = try colors(view, attribute).background
            try await assertRenderedBackground(dark, in: view, name: "before")

            view.scrollingAgentID = "codex"
            let light = try colors(view, attribute).background
            #expect(CodexTerminalColorAdaptation.luminance(light) > 0.65)
            try await assertRenderedBackground(light, in: view, name: "codex-light")
            view.applyTheme(.defaultDark)
            try await assertRenderedBackground(dark, in: view, name: "dark")
        }

        private func makeView() -> InteractiveTerminalView {
            _ = NSApplication.shared
            let view = InteractiveTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 120))
            view.autoFocusEnabled = false
            return view
        }

        private func colors(_ view: InteractiveTerminalView, _ attribute: Attribute) throws -> (foreground: TerminalRGB, background: TerminalRGB) {
            let attributes = try #require(view.terminalView.getAttributes(attribute, withUrl: false))
            return try (rgb(#require(attributes[.foregroundColor] as? NSColor)), rgb(#require(attributes[.backgroundColor] as? NSColor)))
        }

        private func rgb(_ color: NSColor) throws -> TerminalRGB {
            let color = try #require(color.usingColorSpace(.sRGB))
            return TerminalRGB(hex: UInt32((color.redComponent * 255).rounded()) << 16
                | UInt32((color.greenComponent * 255).rounded()) << 8 | UInt32((color.blueComponent * 255).rounded()))
        }

        private func contrast(_ first: TerminalRGB, _ second: TerminalRGB) -> Double {
            let a = CodexTerminalColorAdaptation.luminance(first), b = CodexTerminalColorAdaptation.luminance(second)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        private func assertRenderedBackground(_ expected: TerminalRGB, in view: InteractiveTerminalView, name: String) async throws {
            // SwiftTerm commits display invalidation on the next frame.
            try await Task.sleep(for: .milliseconds(50))
            let terminal = view.terminalView
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: nil, width: Int(terminal.bounds.width), height: Int(terminal.bounds.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            terminal.displayIgnoringOpacity(terminal.bounds, in: NSGraphicsContext(cgContext: context, flipped: false))
            let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            var matchingPixels = 0
            for y in stride(from: 0, to: context.height, by: 2) {
                for x in stride(from: 0, to: context.width, by: 2) {
                    let offset = y * context.bytesPerRow + x * 4
                    if
                        pixels[offset + 3] == 255,
                        abs(Int(pixels[offset]) - Int(expected.red)) <= 1,
                        abs(Int(pixels[offset + 1]) - Int(expected.green)) <= 1,
                        abs(Int(pixels[offset + 2]) - Int(expected.blue)) <= 1 {
                        matchingPixels += 1
                    }
                }
            }
            #expect(matchingPixels > 500, "Composer background must be painted in \(name)")
            if let folder = ProcessInfo.processInfo.environment["CTRLX_TERMINAL_THEME_SNAPSHOTS"] {
                let image = try NSBitmapImageRep(cgImage: #require(context.makeImage()))
                let data = try #require(image.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("mac-\(name).png"))
            }
        }
    }
#endif
