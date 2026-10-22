import CtrlxCommon
import SwiftUI

/// Colors for the application surfaces surrounding a terminal. Keeping these
/// separate from `TerminalThemePalette` lets the terminal retain its exact
/// background while the window chrome uses a deliberate visual hierarchy.
struct TerminalWorkspacePalette: Equatable, Sendable {
    struct Surface: Equatable, Sendable {
        let color: TerminalRGB
        let alpha: UInt8

        init(hex: UInt32, alpha: UInt8 = 0xFF) {
            self.color = TerminalRGB(hex: hex)
            self.alpha = alpha
        }

        init(color: TerminalRGB, alpha: UInt8 = 0xFF) {
            self.color = color
            self.alpha = alpha
        }

        var swiftUIColor: SwiftUI.Color {
            SwiftUI.Color(
                .sRGB,
                red: Double(color.red) / 255,
                green: Double(color.green) / 255,
                blue: Double(color.blue) / 255,
                opacity: Double(alpha) / 255
            )
        }
    }

    let sidebarBackground: Surface
    let workspaceBackground: Surface
    let chromeBackground: Surface
    let activeTabBackground: Surface
    let border: Surface
    let selectedSidebarRow: Surface
}

extension TerminalTheme {
    /// SwiftUI colors for the terminal workbench chrome.
    var sidebarBackgroundColor: SwiftUI.Color {
        workspacePalette.sidebarBackground.swiftUIColor
    }

    var workspaceBackgroundColor: SwiftUI.Color {
        workspacePalette.workspaceBackground.swiftUIColor
    }

    var chromeBackgroundColor: SwiftUI.Color {
        workspacePalette.chromeBackground.swiftUIColor
    }

    var activeTabBackgroundColor: SwiftUI.Color {
        workspacePalette.activeTabBackground.swiftUIColor
    }

    var workspaceBorderColor: SwiftUI.Color {
        workspacePalette.border.swiftUIColor
    }

    var selectedSidebarRowBackgroundColor: SwiftUI.Color {
        switch self {
        case .anysphereDark,
             .codexLight:
            workspacePalette.selectedSidebarRow.swiftUIColor
        default:
            SwiftUI.Color.accentColor.opacity(0.2)
        }
    }

    var workspaceForegroundColor: SwiftUI.Color {
        SwiftUI.Color(nsColor: palette.foreground.nativeColor)
    }

    var workspacePrimaryTextColor: SwiftUI.Color {
        self == .codexLight ? workspaceForegroundColor : .primary
    }

    var workspaceSecondaryTextColor: SwiftUI.Color {
        self == .codexLight ? SwiftUI.Color(nsColor: TerminalRGB(hex: 0x626262).nativeColor) : .secondary
    }

    var sidebarPrimaryTextColor: SwiftUI.Color {
        self == .codexLight ? SwiftUI.Color(nsColor: TerminalRGB(hex: 0x212121).nativeColor) : .primary
    }

    var workspaceAccentColor: SwiftUI.Color {
        self == .codexLight ? SwiftUI.Color(nsColor: TerminalRGB(hex: 0x0169CC).nativeColor) : .accentColor
    }

    var usesSubtleTabBorder: Bool {
        self == .anysphereDark || self == .codexLight
    }

    var workspaceColorScheme: SwiftUI.ColorScheme {
        switch self {
        case .defaultDark,
             .solarizedDark,
             .anysphereDark:
            .dark
        case .defaultLight,
             .solarizedLight,
             .codexLight:
            .light
        }
    }

    var workspacePalette: TerminalWorkspacePalette {
        let terminalPalette = palette

        return switch self {
        case .codexLight:
            TerminalWorkspacePalette(
                sidebarBackground: .init(hex: 0xFCFCFC),
                workspaceBackground: .init(hex: 0xFFFFFF),
                chromeBackground: .init(hex: 0xFCFCFC),
                activeTabBackground: .init(hex: 0xEDEDED),
                border: .init(hex: 0xE5E5E5),
                selectedSidebarRow: .init(hex: 0xEDEDED)
            )
        case .anysphereDark:
            TerminalWorkspacePalette(
                sidebarBackground: .init(hex: 0x141414),
                workspaceBackground: .init(hex: 0x181818),
                chromeBackground: .init(hex: 0x202020, alpha: 0xCC),
                activeTabBackground: .init(hex: 0x181818),
                border: .init(hex: 0x303030),
                selectedSidebarRow: .init(hex: 0x1C1C1C)
            )
        default:
            TerminalWorkspacePalette(
                sidebarBackground: .init(color: terminalPalette.background),
                workspaceBackground: .init(color: terminalPalette.background),
                chromeBackground: .init(color: terminalPalette.background),
                activeTabBackground: .init(color: terminalPalette.foreground, alpha: 0x14),
                border: .init(color: terminalPalette.foreground, alpha: 0x73),
                // Other themes continue using the system accent color.
                selectedSidebarRow: .init(color: terminalPalette.background)
            )
        }
    }
}
