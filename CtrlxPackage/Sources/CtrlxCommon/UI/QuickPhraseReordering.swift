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

    func body(content: Content) -> some View {
        content
            .draggable(QuickPhraseDragPayload(id: phrase.id)) {
                Text(phrase.text)
                    .padding(12)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
            .dropDestination(for: QuickPhraseDragPayload.self) { items, _ in
                guard items.count == 1, let item = items.first else { return false }
                return move(item.id, to: phrase.id)
            }
            .accessibilityAction(named: "Move Earlier") { moveBy(-1) }
            .accessibilityAction(named: "Move Later") { moveBy(1) }
    }

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
