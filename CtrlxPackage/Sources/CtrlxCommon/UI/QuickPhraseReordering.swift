import SwiftUI
import UniformTypeIdentifiers

package struct QuickPhraseDragPayload: Codable, Transferable, Sendable {
    package let id: UUID
    fileprivate static let contentType = UTType(exportedAs: "com.jicezeng.ctrlx.quick-phrase")

    package static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}

@MainActor
private struct QuickPhraseReordering: ViewModifier, DropDelegate {
    let phrase: QuickPhrase
    let store: QuickPhraseStore
    let reportError: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0
    @State private var insertionSide: InsertionSide?

    func body(content: Content) -> some View {
        content
            .draggable(QuickPhraseDragPayload(id: phrase.id)) {
                Text(phrase.text)
                    .padding(12)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
            .overlay(alignment: insertionSide == .after ? .trailing : .leading) {
                if insertionSide != nil {
                    DropInsertionIndicator(axis: .horizontal)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
            .onDrop(of: [QuickPhraseDragPayload.contentType], delegate: self)
            .accessibilityAction(named: "Move Earlier") { moveBy(-1) }
            .accessibilityAction(named: "Move Later") { moveBy(1) }
    }

    func dropEntered(info: DropInfo) {
        _ = dropUpdated(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let side = InsertionSide(position: info.location.x, length: width)
        if insertionSide != side {
            insertionSide = side
        }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        insertionSide = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { insertionSide = nil }
        let type = QuickPhraseDragPayload.contentType
        let providers = info.itemProviders(for: [type])
        guard providers.count == 1, let provider = providers.first else { return false }
        let side = InsertionSide(position: info.location.x, length: width)
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let item = try? JSONDecoder().decode(QuickPhraseDragPayload.self, from: data) else { return }
            Task { @MainActor in _ = move(item.id, to: phrase.id, side: side) }
        }
        return true
    }

    private func move(_ id: UUID, to target: UUID, side: InsertionSide? = nil) -> Bool {
        do {
            return try withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                try store.move(id, to: target, side: side)
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
