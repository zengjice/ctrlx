#if os(macOS)
    import AppKit
    import SwiftUI

    /// Own the column width independently of the selected preview's identity and ideal size.
    struct FileBrowserSplitView<Directory: View, Preview: View>: View {
        @ViewBuilder var directory: Directory
        @ViewBuilder var preview: Preview
        @State private var directoryWidth: CGFloat = 280
        @GestureState private var dragTranslation: CGFloat = 0
        @State private var cursorPushed = false

        var body: some View {
            GeometryReader { geometry in
                let available = max(0, geometry.size.width - 8)
                let minimum = min(200, available / 2)
                let clamp: (CGFloat) -> CGFloat = { min(max($0, minimum), available - minimum) }
                let startWidth = clamp(directoryWidth)
                HStack(spacing: 0) {
                    directory
                        .frame(width: clamp(startWidth + dragTranslation))
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .clipped()
                    Color.clear
                        .overlay { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1) }
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            guard hovering != cursorPushed else { return }
                            if hovering {
                                NSCursor.resizeLeftRight.push()
                            } else {
                                NSCursor.pop()
                            }
                            cursorPushed = hovering
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                .updating($dragTranslation) { value, state, _ in state = value.translation.width }
                                .onEnded { directoryWidth = clamp(startWidth + $0.translation.width) }
                        )
                        .accessibilityElement()
                        .accessibilityLabel("Resize file list")
                        .accessibilityValue("\(Int(startWidth)) points")
                        .accessibilityIdentifier("file-browser-divider")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: directoryWidth = clamp(startWidth + 40)
                            case .decrement: directoryWidth = clamp(startWidth - 40)
                            @unknown default: break
                            }
                        }
                    preview
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .clipped()
                }
            }
            .onDisappear {
                if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
        }
    }
#endif
