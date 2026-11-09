import AppKit
import CtrlxCommon
import SwiftUI

/// A read-only sample using the same font fallback and palette as the terminal.
struct TerminalAppearancePreview: View {
    let fontName: String
    let fontSize: Double
    let theme: TerminalTheme

    private var font: Font {
        Font(NSFont(name: fontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
    }

    var body: some View {
        let palette = theme.palette
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 5) {
                Text("~/Projects/ctrlx $ git status")
                Text("On branch main")
                Text("✓ Working tree clean").foregroundStyle(Color(nsColor: palette.ansiColors[2].nativeColor))
                Text("› Ready for your next task ▌").foregroundStyle(Color(nsColor: palette.ansiColors[6].nativeColor))
            }
            .font(font)
            .foregroundStyle(Color(nsColor: palette.foreground.nativeColor))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: palette.background.nativeColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Terminal preview, \(fontName), \(Int(fontSize)) points, \(theme.rawValue)")
        .accessibilityIdentifier("settings-terminal-preview")
    }
}
