#if os(macOS) || os(iOS)
    import Foundation
    import SwiftTerm
    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    public enum TerminalTheme: String, CaseIterable, Sendable {
        case defaultDark = "Default Dark"
        case defaultLight = "Default Light"
        case codexLight = "Codex Light"
        case solarizedDark = "Solarized Dark"
        case solarizedLight = "Solarized Light"
        case anysphereDark = "Anysphere Dark"
    }

    /// An RGB color shared by SwiftTerm rendering, rich-text copy, and tmux OSC
    /// color declarations.
    public struct TerminalRGB: Equatable, Sendable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8

        public init(hex: UInt32) {
            self.red = UInt8((hex >> 16) & 0xFF)
            self.green = UInt8((hex >> 8) & 0xFF)
            self.blue = UInt8(hex & 0xFF)
        }

        #if os(macOS)
            public var nativeColor: NSColor {
                NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
            }
        #elseif os(iOS)
            public var nativeColor: UIColor {
                UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
            }
        #endif

        public var swiftTermColor: SwiftTerm.Color {
            SwiftTerm.Color(
                red: UInt16(red) * 257,
                green: UInt16(green) * 257,
                blue: UInt16(blue) * 257
            )
        }

        public var oscValue: String {
            String(
                format: "%02x%02x/%02x%02x/%02x%02x",
                red, red,
                green, green,
                blue, blue
            )
        }
    }

    /// Complete terminal palette. ANSI colors always contains exactly 16 entries.
    public struct TerminalThemePalette: Sendable {
        public let foreground: TerminalRGB
        public let background: TerminalRGB
        public let ansiColors: [TerminalRGB]

        #if os(macOS)
            public var nativeANSIColors: [NSColor] {
                ansiColors.map(\.nativeColor)
            }
        #endif

        public var swiftTermANSIColors: [SwiftTerm.Color] {
            ansiColors.map(\.swiftTermColor)
        }

        public static let swiftTermDefaultANSI: [TerminalRGB] = [
            0x000000, 0xC23621, 0x25BC24, 0xADAD27,
            0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
            0x818383, 0xFC391F, 0x31E722, 0xEAEC23,
            0x5833FF, 0xF935F8, 0x14F0F0, 0xE9EBEB,
        ].map(TerminalRGB.init(hex:))

        public static let anysphereDarkANSI: [TerminalRGB] = [
            0x242424, 0xFC6B83, 0x3FA266, 0xD2943E,
            0x81A1C1, 0xB48EAD, 0x88C0D0, 0xF0F0F0,
            0x989898, 0xFC6B83, 0x70B489, 0xF1B467,
            0x87A6C4, 0xB48EAD, 0x88C0D0, 0xFFFFFF,
        ].map(TerminalRGB.init(hex:))

        /// Based on Codex Light's syntax colors. Bright chromatic slots stay dark
        /// enough for white backgrounds, including when bold promotes an ANSI color.
        /// White slots retain their terminal meaning for backgrounds/reverse video.
        public static let codexLightANSI: [TerminalRGB] = [
            0x0D0D0D, 0xD53538, 0x008809, 0xBD5800,
            0x0169CC, 0x751ED9, 0x007F8B, 0xCDCDCD,
            0x666666, 0xD53538, 0x008809, 0xBD5800,
            0x0071EA, 0x751ED9, 0x007F8B, 0xFFFFFF,
        ].map(TerminalRGB.init(hex:))
    }

    public extension TerminalTheme {
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
#endif
