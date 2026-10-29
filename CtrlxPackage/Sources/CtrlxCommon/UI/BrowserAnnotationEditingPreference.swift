#if os(macOS) || os(iOS)
    import SwiftUI

    public struct BrowserAnnotationEditingPreference: PreferenceKey {
        public static var defaultValue: Bool {
            false
        }

        public static func reduce(value: inout Bool, nextValue: () -> Bool) {
            value = value || nextValue()
        }
    }
#endif
