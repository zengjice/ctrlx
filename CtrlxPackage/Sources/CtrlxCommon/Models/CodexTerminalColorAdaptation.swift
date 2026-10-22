#if os(macOS) || os(iOS)
    import Foundation

    /// Codex chooses explicit colors using the Host's background at startup.
    /// Adapt their display to the local Mac/iOS theme without changing terminal data.
    public enum CodexTerminalColorAdaptation {
        public static func isLight(_ palette: TerminalThemePalette) -> Bool {
            luminance(palette.background) > 0.5
        }

        public static func color(_ color: TerminalRGB, foreground: Bool, inverse: Bool = false, palette: TerminalThemePalette) -> TerminalRGB {
            // Reverse video may pair an explicit background with a default
            // inverted foreground, which bypasses this mapping. Preserve the
            // resolved pair rather than changing only its explicit member.
            guard !inverse else { return color }
            let light = isLight(palette)
            // Reserve contrast for shaded surfaces. On dark themes, preserve
            // dark backgrounds through #444444 and dim brighter surfaces.
            let background = light ? luminance(palette.background) * 0.82
                : max(luminance(palette.background), luminance(.init(hex: 0x444444)))
            if !foreground {
                guard light ? luminance(color) < 0.5 : luminance(color) > background else { return color }
                return mix(color, toward: palette.background, amount: 0.92)
            }
            // Leave readable colors alone; move low-contrast text toward black
            // or white while retaining its hue.
            let target = TerminalRGB(hex: light ? 0 : 0xFFFFFF)
            func contrast(_ color: TerminalRGB) -> Double {
                light ? (background + 0.05) / (luminance(color) + 0.05)
                    : (luminance(color) + 0.05) / (background + 0.05)
            }
            guard contrast(color) < 4.5 else { return color }
            var low = 0.0
            var high = 1.0
            for _ in 0..<10 {
                let amount = (low + high) / 2
                if contrast(mix(color, toward: target, amount: amount)) < 4.5 {
                    low = amount
                } else {
                    high = amount
                }
            }
            return mix(color, toward: target, amount: high)
        }

        public static func luminance(_ color: TerminalRGB) -> Double {
            func linear(_ channel: UInt8) -> Double {
                let value = Double(channel) / 255
                return value <= 0.04_045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2_126 * linear(color.red) + 0.7_152 * linear(color.green) + 0.0_722 * linear(color.blue)
        }

        private static func mix(_ color: TerminalRGB, toward target: TerminalRGB, amount: Double) -> TerminalRGB {
            func channel(_ source: UInt8, _ target: UInt8) -> UInt32 {
                UInt32((Double(source) + (Double(target) - Double(source)) * amount).rounded())
            }
            return TerminalRGB(hex: channel(color.red, target.red) << 16
                | channel(color.green, target.green) << 8 | channel(color.blue, target.blue))
        }
    }
#endif
