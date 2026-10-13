import CtrlxCommon
import SwiftUI

struct SessionSwitcherItem: Identifiable, Equatable {
    let id: SidebarSessionSelection
    let name: String
    let title: String
    let host: String
    var isAvailable = true

    var accessibilityID: String {
        switch id {
        case let .local(name): "session-switcher-result-local-\(name)"
        case let .remote(hostID, name): "session-switcher-result-remote-\(hostID)-\(name)"
        }
    }

    static func matching(_ items: [Self], query: String) -> [Self] {
        let words = query.split(whereSeparator: \.isWhitespace)
        return items.filter { item in
            words.allSatisfy { word in
                [item.name, item.title, item.host].contains { $0.localizedStandardContains(String(word)) }
            }
        }
    }
}

struct SessionSwitcherView: View {
    let items: [SessionSwitcherItem]
    let current: SidebarSessionSelection?
    let onSelect: (SidebarSessionSelection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: SidebarSessionSelection?
    @FocusState private var searchFocused: Bool

    private var matches: [SessionSwitcherItem] {
        SessionSwitcherItem.matching(items, query: query)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Switch Session").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search sessions or hosts…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier("session-switcher-search")
                .onSubmit(openSelection)
                .onKeyPress(.downArrow) {
                    moveSelection(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(-1)
                    return .handled
                }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches) { item in
                            Button { open(item) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).lineLimit(1)
                                        Text("\(item.host) · \(item.name)\(item.isAvailable ? "" : " · Offline")")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if item.id == current {
                                        Symbols.checkmark.image
                                    }
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selection == item.id ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!item.isAvailable)
                            .id(item.id)
                            .accessibilityIdentifier(item.accessibilityID)
                        }
                    }
                }
                .overlay {
                    if matches.isEmpty {
                        Text("No matching sessions").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: selection) { _, id in
                    if let id {
                        proxy.scrollTo(id)
                    }
                }
            }
            HStack {
                Text("↑ ↓ to choose · Esc to cancel")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Switch", action: openSelection)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!matches.contains { $0.id == selection && $0.isAvailable })
            }
        }
        .padding(16)
        .frame(width: 440, height: 360)
        .task {
            selection = items.first { $0.id == current && $0.isAvailable }?.id
                ?? matches.first(where: \.isAvailable)?.id
            searchFocused = true
        }
        .onChange(of: matches) {
            if !matches.contains(where: { $0.id == selection && $0.isAvailable }) {
                selection = matches.first(where: \.isAvailable)?.id
            }
        }
    }

    private func moveSelection(_ direction: Int) {
        let available = matches.filter(\.isAvailable)
        guard !available.isEmpty else {
            selection = nil
            return
        }
        let index = selection.flatMap { id in available.firstIndex { $0.id == id } }
            ?? (direction > 0 ? -1 : available.count)
        selection = available[(index + direction + available.count) % available.count].id
    }

    private func openSelection() {
        guard let item = matches.first(where: { $0.id == selection }) else { return }
        open(item)
    }

    private func open(_ item: SessionSwitcherItem) {
        guard item.isAvailable else { return }
        dismiss()
        onSelect(item.id)
    }
}
