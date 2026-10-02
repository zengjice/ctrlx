import SwiftUI
import UniformTypeIdentifiers

package struct QuickPhraseDragPayload: Codable, Transferable, Sendable {
    package let id: UUID

    package static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "com.jicezeng.ctrlx.quick-phrase"))
    }
}

@MainActor
private struct QuickPhraseReordering: ViewModifier {
    let phrase: QuickPhrase
    let store: QuickPhraseStore
    let reportError: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
        @State private var isTargeted = false
    #endif

    func body(content: Content) -> some View {
        content
            .draggable(QuickPhraseDragPayload(id: phrase.id)) {
                Text(phrase.text)
                    .padding(12)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
            .dropDestination(for: QuickPhraseDragPayload.self) { items, _ in
                #if os(iOS)
                    isTargeted = false
                #endif
                guard items.count == 1, let item = items.first else { return false }
                return move(item.id, to: phrase.id)
            } isTargeted: { targeted in
                #if os(iOS)
                    if isTargeted != targeted { isTargeted = targeted }
                #endif
            }
            #if os(iOS)
                .overlay {
                    dropIndicator
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            #endif
            .accessibilityAction(named: "Move Earlier") { moveBy(-1) }
            .accessibilityAction(named: "Move Later") { moveBy(1) }
    }

    #if os(iOS)
        @ViewBuilder
        private var dropIndicator: some View {
            if isTargeted, let index = store.phrases.firstIndex(where: { $0.id == phrase.id }) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.15))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [6, 3]))
                    }
                    .overlay(alignment: .topTrailing) {
                        Text("Drop at #\(index + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.background, in: .capsule)
                            .offset(x: 4, y: -8)
                    }
                    .accessibilityIdentifier("quick-phrase-drop-target-\(phrase.id)")
            }
        }
    #endif

    private func move(_ id: UUID, to target: UUID) -> Bool {
        do {
            return try withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                try store.move(id, to: target)
            }
        } catch {
            reportError(error.localizedDescription)
            return false
        }
    }

    private func moveBy(_ offset: Int) {
        guard let index = store.phrases.firstIndex(where: { $0.id == phrase.id }),
              store.phrases.indices.contains(index + offset) else { return }
        _ = move(phrase.id, to: store.phrases[index + offset].id)
    }
}

extension View {
    @MainActor
    package func quickPhraseReordering(_ phrase: QuickPhrase, store: QuickPhraseStore,
                                      reportError: @escaping (String) -> Void) -> some View {
        modifier(QuickPhraseReordering(phrase: phrase, store: store, reportError: reportError))
    }
}
