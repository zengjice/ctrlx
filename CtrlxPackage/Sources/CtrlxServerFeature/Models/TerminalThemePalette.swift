import AppKit
import Foundation
import SwiftTerm
import SwiftUI

/// An RGB color shared by SwiftTerm rendering, rich-text copy, and tmux OSC
/// color declarations.
struct TerminalRGB: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(hex: UInt32) {
        self.red = UInt8((hex >> 16) & 0xFF)
        self.green = UInt8((hex >> 8) & 0xFF)
        self.blue = UInt8(hex & 0xFF)
    }

    var nativeColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    var swiftTermColor: SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16(red) * 257,
            green: UInt16(green) * 257,
            blue: UInt16(blue) * 257
        )
    }

    var oscValue: String {
        String(
            format: "%02x%02x/%02x%02x/%02x%02x",
            red, red,
            green, green,
            blue, blue
        )
    }
}

/// Complete terminal palette. ANSI colors always contains exactly 16 entries.
struct TerminalThemePalette: Sendable {
    let foreground: TerminalRGB
    let background: TerminalRGB
    let ansiColors: [TerminalRGB]

    var nativeANSIColors: [NSColor] {
        ansiColors.map(\.nativeColor)
    }

    var swiftTermANSIColors: [SwiftTerm.Color] {
        ansiColors.map(\.swiftTermColor)
    }

    static let swiftTermDefaultANSI: [TerminalRGB] = [
        0x000000, 0xC23621, 0x25BC24, 0xADAD27,
        0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
        0x818383, 0xFC391F, 0x31E722, 0xEAEC23,
        0x5833FF, 0xF935F8, 0x14F0F0, 0xE9EBEB,
    ].map(TerminalRGB.init(hex:))

    static let anysphereDarkANSI: [TerminalRGB] = [
        0x242424, 0xFC6B83, 0x3FA266, 0xD2943E,
        0x81A1C1, 0xB48EAD, 0x88C0D0, 0xF0F0F0,
        0x989898, 0xFC6B83, 0x70B489, 0xF1B467,
        0x87A6C4, 0xB48EAD, 0x88C0D0, 0xFFFFFF,
    ].map(TerminalRGB.init(hex:))

    /// Based on Codex Light's syntax colors. Bright chromatic slots stay dark
    /// enough for white backgrounds, including when bold promotes an ANSI color.
    /// White slots retain their terminal meaning for backgrounds/reverse video.
    static let codexLightANSI: [TerminalRGB] = [
        0x0D0D0D, 0xD53538, 0x008809, 0xBD5800,
        0x0169CC, 0x751ED9, 0x007F8B, 0xCDCDCD,
        0x666666, 0xD53538, 0x008809, 0xBD5800,
        0x0071EA, 0x751ED9, 0x007F8B, 0xFFFFFF,
    ].map(TerminalRGB.init(hex:))
}

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
                activeTabBackground: .init(hex: 0xFFFFFF),
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

    var palette: TerminalThemePalette {
        switch self {
        case .defaultDark:
            TerminalThemePalette(
                foreground: TerminalRGB(hex: 0xE6E6E6),
                // macOS dark Aqua's window background color.
                background: TerminalRGB(hex: 0x1E1E1E),
                ansiColors: TerminalThemePalette.swiftTermDefaultANSI
            )
        case .defaultLight:
            TerminalThemePalette(
                foreground: TerminalRGB(hex: 0x1A1A1A),
                background: TerminalRGB(hex: 0xF2F2F2),
                ansiColors: TerminalThemePalette.swiftTermDefaultANSI
            )
        case .codexLight:
            TerminalThemePalette(
                foreground: TerminalRGB(hex: 0x0D0D0D),
                background: TerminalRGB(hex: 0xFFFFFF),
                ansiColors: TerminalThemePalette.codexLightANSI
            )
        case .solarizedDark:
            TerminalThemePalette(
                foreground: TerminalRGB(hex: 0xE6E6E6),
                background: TerminalRGB(hex: 0x1A1A1A),
                ansiColors: TerminalThemePalette.swiftTermDefaultANSI
            )
        case .solarizedLight:
            TerminalThemePalette(
                foreground: TerminalRGB(hex: 0x1A1A1A),
                background: TerminalRGB(hex: 0xF2F2F2),
                ansiColors: TerminalThemePalette.swiftTermDefaultANSI
            )
        case .anysphereDark:
            TerminalThemePalette(
                foreground: TerminalRGB(hex: 0xF0F0F0),
                background: TerminalRGB(hex: 0x141414),
                ansiColors: TerminalThemePalette.anysphereDarkANSI
            )
        }
    }
}
