import AppKit
import CtrlxCommon
import Dependencies
import SwiftUI

@MainActor
struct AgentNotesView: View {
    let store: AgentNotesStore
    let scope: AgentNoteScope
    let title: String
    let isAvailable: @MainActor () -> Bool
    let registerClose: (@escaping (Bool) -> Bool) -> Void
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Dependency(ClipboardClient.self) private var clipboard
    @State private var editing: Bool
    @State private var noteID: UUID?
    @State private var draft = ""
    @State private var editorID = UUID()
    @State private var selectedIndex = 0
    @State private var page = 0
    @State private var expanded = false
    @State private var closing = false
    @State private var error: String?
    @FocusState private var listFocused: Bool

    init(
        store: AgentNotesStore,
        scope: AgentNoteScope,
        title: String,
        newNote: Bool,
        isAvailable: @escaping @MainActor () -> Bool,
        registerClose: @escaping (@escaping (Bool) -> Bool) -> Void,
        close: @escaping () -> Void
    ) {
        self.store = store
        self.scope = scope
        self.title = title
        self.isAvailable = isAvailable
        self.registerClose = registerClose
        self.close = close
        _editing = State(initialValue: newNote)
    }

    private var notes: [AgentNote] {
        store.notes(for: scope)
    }

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Symbols.noteText.image.foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(editing ? (noteID == nil ? "New Note" : "Note") : "Agent Notes").font(.headline)
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if editing {
                    Button { showList() } label: { Symbols.rectangleStack.image }
                        .help("Show Notes (⌘⌥N)").accessibilityLabel("Show Notes")
                        .keyboardShortcut("n", modifiers: [.command, .option])
                }
                Button { beginNew() } label: { Symbols.plus.image }
                    .help("New Note (⌘⇧N)").accessibilityLabel("New Note")
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(store.issue != nil)
                Button { _ = finish(animated: true) } label: { Symbols.xmark.image }
                    .help("Save and close (Esc)").accessibilityLabel("Close Notes")
                    .keyboardShortcut("w", modifiers: .command)
            }
            .buttonStyle(.borderless)
            .padding(20)
            if let issue = error ?? store.issue {
                Text(issue).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
            if store.issue != nil {
                ContentUnavailableView("Notes unavailable", symbol: .exclamationmarkTriangle, description: "Your saved notes have been kept.")
            } else if editing {
                editor
            } else if notes.isEmpty {
                VStack(spacing: 14) {
                    Symbols.noteText.image.font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
                    Text("No notes for this Agent yet").font(.headline)
                    Text("Paste a thought, a command, or a piece of text.").foregroundStyle(.secondary)
                    Button("New Note") { beginNew() }.buttonStyle(.borderedProminent)
                        .disabled(store.issue != nil)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                cards
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.1)))
        .opacity(closing ? 0 : 1)
        .scaleEffect(closing && !reduceMotion ? 0.96 : 1, anchor: .bottom)
        .onExitCommand { _ = finish(animated: true) }
        .onAppear { registerClose { animated in finish(animated: animated) } }
        .task(id: closing) {
            guard closing else { return }
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 70 : 200)) }
            catch { return }
            close()
        }
        .onChange(of: notes.count) { _, count in selectedIndex = min(selectedIndex, max(0, count - 1)) }
    }

    private var editor: some View {
        VStack(spacing: 14) {
            AgentNoteTextEditor(text: $draft, selectAll: noteID != nil, onEscape: { _ = finish(animated: true) })
                .id(editorID)
                .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Paste or type a note…").foregroundStyle(.tertiary).padding(14).allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("agent-note-editor")
            HStack {
                if let noteID {
                    Button(role: .destructive) { delete(noteID) } label: { Label("Delete", symbol: .trash) }
                    Button { clipboard.setString(draft) } label: { Label("Copy", symbol: .docOnDoc) }.disabled(!hasText)
                }
                Spacer()
                Text("Esc saves and closes").font(.caption).foregroundStyle(.secondary)
                Button("Save & Close") { _ = finish(animated: true) }
                    .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
                    .disabled(!hasText || store.issue != nil)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 20)
    }

    private var cards: some View {
        GeometryReader { geometry in
            let pageSize = max(1, min(7, Int((geometry.size.width - 80) / 100)))
            let pageCount = max(1, (notes.count + pageSize - 1) / pageSize)
            let currentPage = min(page, pageCount - 1)
            let start = currentPage * pageSize
            let visible = Array(notes.dropFirst(start).prefix(pageSize))
            VStack(spacing: 0) {
                ZStack {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, note in
                        let position = AgentNoteFanPosition(index: index, count: visible.count, width: geometry.size.width)
                        let positioned = (expanded && !closing) || reduceMotion
                        Button { open(note) } label: {
                            AgentNoteCard(note: note, colorIndex: start + index, selected: selectedIndex == start + index)
                        }
                        .buttonStyle(.plain)
                        .rotationEffect(.degrees(positioned ? position.angle : 0), anchor: .bottom)
                        .scaleEffect(positioned ? 1 : 0.15, anchor: .bottom)
                        .offset(
                            x: positioned ? position.x : 0,
                            y: positioned ? position.y : 220
                        )
                        .opacity(expanded && !closing ? 1 : 0)
                        .zIndex(selectedIndex == start + index ? 100 : Double(index))
                        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.4, bounce: 0.18).delay(Double(index) * 0.018), value: expanded && !closing)
                        .onHover {
                            if $0 {
                                selectedIndex = start + index
                            }
                        }
                        .contextMenu {
                            Button("Open") { open(note) }
                            Button("Copy") { clipboard.setString(note.text) }
                            Divider()
                            Button("Delete", role: .destructive) { delete(note.id) }
                        }
                        .accessibilityLabel("Note \(start + index + 1): \(String(note.text.prefix(100)))")
                        .accessibilityHint("Open and select all text")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Text("\(notes.count) notes · Select a card to copy or edit")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if pageCount > 1 {
                        Button { page = max(0, currentPage - 1)
                            selectedIndex = page * pageSize
                        } label: { Symbols.chevronLeft.image }
                            .disabled(currentPage == 0).accessibilityLabel("Previous Notes")
                        Text("\(currentPage + 1) / \(pageCount)").font(.caption.monospacedDigit())
                        Button { page = min(pageCount - 1, currentPage + 1)
                            selectedIndex = page * pageSize
                        } label: { Symbols.chevronRight.image }
                            .disabled(currentPage == pageCount - 1).accessibilityLabel("Next Notes")
                    }
                }
                .padding(20)
            }
            .focusable().focused($listFocused).focusEffectDisabled()
            .onKeyPress(.leftArrow) { moveSelection(-1, pageSize: pageSize)
                return .handled
            }
            .onKeyPress(.rightArrow) { moveSelection(1, pageSize: pageSize)
                return .handled
            }
            .onKeyPress(.return) {
                guard !notes.isEmpty else { return .ignored }
                open(notes[min(selectedIndex, notes.count - 1)])
                return .handled
            }
            .task(id: currentPage) {
                expanded = false
                await Task.yield()
                guard !Task.isCancelled else { return }
                expanded = true
                listFocused = true
            }
        }
    }

    private func moveSelection(_ delta: Int, pageSize: Int) {
        guard !notes.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), notes.count - 1)
        page = selectedIndex / pageSize
    }

    private func saveDraft() -> Bool {
        guard isAvailable() else { close()
            return false
        }
        guard editing, hasText else { return true }
        do {
            noteID = try store.save(draft, id: noteID, for: scope)
            error = nil
            return true
        } catch { self.error = error.localizedDescription
            return false
        }
    }

    private func finish(animated: Bool) -> Bool {
        if closing {
            if !animated {
                close()
            }
            return true
        }
        guard saveDraft() else { return false }
        if animated {
            withAnimation(.easeOut(duration: 0.18)) { closing = true }
        } else {
            close()
        }
        return true
    }

    private func beginNew() {
        guard saveDraft() else { return }
        noteID = nil
        draft = ""
        editing = true
        editorID = UUID()
    }

    private func showList() {
        guard saveDraft() else { return }
        editing = false
        expanded = false
        page = 0
        selectedIndex = 0
    }

    private func open(_ note: AgentNote) {
        noteID = note.id
        draft = note.text
        editorID = UUID()
        editing = true
    }

    private func delete(_ id: UUID) {
        do {
            try withAnimation(.spring(duration: 0.25)) { try store.delete(id, for: scope) }
            noteID = nil
            draft = ""
            editing = false
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct AgentNoteCard: View {
    let note: AgentNote
    let colorIndex: Int
    var selected = false
    private let colors: [Color] = [.pink, .orange, .yellow, .green, .mint, .cyan, .purple]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 2).fill(colors[colorIndex % colors.count].opacity(0.65)).frame(width: 32, height: 4)
            Text(note.preview).font(.system(size: 14)).foregroundStyle(.primary)
                .lineLimit(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text(note.updatedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 184, height: 244)
        .background(.background)
        .background(colors[colorIndex % colors.count].opacity(0.2))
        .overlay(colors[colorIndex % colors.count].opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(selected ? colors[colorIndex % colors.count].opacity(0.7) : .primary.opacity(0.1), lineWidth: selected ? 1.5 : 0.5))
        .shadow(color: .black.opacity(selected ? 0.2 : 0.1), radius: selected ? 16 : 8, x: 0, y: 6)
    }
}

struct AgentNoteTextEditor: NSViewRepresentable {
    @Binding var text: String
    let selectAll: Bool
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = AgentNoteNativeTextView()
        editor.isRichText = false
        editor.frame = .init(x: 0, y: 0, width: 640, height: 330)
        editor.minSize = .init(width: 0, height: 280)
        editor.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 15)
        editor.textColor = .labelColor
        editor.insertionPointColor = .controlAccentColor
        editor.textContainerInset = .init(width: 10, height: 12)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = .init(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.string = text
        editor.selectOnFocus = selectAll
        editor.onEscape = onEscape
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let editor = view.documentView as? AgentNoteNativeTextView {
            if editor.string != text, !editor.hasMarkedText() {
                editor.string = text
            }
            editor.onEscape = onEscape
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AgentNoteTextEditor
        init(_ parent: AgentNoteTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView {
                parent.text = editor.string
            }
        }
    }
}

final class AgentNoteNativeTextView: NSTextView {
    var selectOnFocus = false
    var onEscape: (() -> Void)?
    private var focusTask: Task<Void, Never>?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTask?.cancel()
        guard let window else { return }
        focusTask = Task { @MainActor [weak self, weak window] in
            await Task.yield()
            guard !Task.isCancelled, let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
            if selectOnFocus {
                selectAll(nil)
            }
        }
    }

    override func cancelOperation(_: Any?) {
        onEscape?()
    }
}
