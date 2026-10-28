import CtrlxNetworking
import SwiftUI

@MainActor
public struct BrowserBookmarksButton: View {
    let url: String
    let navigationUnavailableReason: String?
    let request: @MainActor (BrowserBookmarkOperation) async throws -> [BrowserBookmark]
    let navigate: @MainActor (String) -> Void
    @State private var isPresented = false
    @State private var bookmarks: [BrowserBookmark]?
    @State private var error: String?
    @State private var isBusy = true
    @State private var operation = BrowserBookmarkOperation.list
    @State private var requestID = UUID()

    public init(
        url: String,
        navigationUnavailableReason: String?,
        request: @escaping @MainActor (BrowserBookmarkOperation) async throws -> [BrowserBookmark],
        navigate: @escaping @MainActor (String) -> Void
    ) {
        self.url = url
        self.navigationUnavailableReason = navigationUnavailableReason
        self.request = request
        self.navigate = navigate
    }

    private var isSaved: Bool {
        guard let address = BrowserBookmark.normalizedURL(url) else { return false }
        return bookmarks?.contains { $0.url == address } == true
    }

    public var body: some View {
        Button {
            isPresented = true
            enqueue(.list)
        } label: {
            Label("Bookmarks", symbol: isSaved ? .bookmarkFill : .bookmark)
        }
        .labelStyle(.iconOnly)
        .help(isSaved ? "Bookmarks · Current page saved" : "Bookmarks")
        .accessibilityIdentifier("browser-bookmarks")
        .accessibilityValue(isSaved ? "Current page saved" : "Current page not saved")
        #if os(macOS)
            .popover(isPresented: $isPresented) { panel.frame(width: 360, height: 440) }
        #else
            .sheet(isPresented: $isPresented) {
                panel.presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        #endif
            .onChange(of: url) { _, _ in enqueue(.list) }
            .task(id: requestID) {
                let id = requestID
                defer {
                    if requestID == id {
                        isBusy = false
                        operation = .list
                    }
                }
                do {
                    let result = try await request(operation)
                    try Task.checkCancellation()
                    guard requestID == id else { return }
                    bookmarks = result
                    error = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard requestID == id, !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
            }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bookmarks").font(.headline)
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Done") { isPresented = false }
            }.padding()
            Divider()
            Button { enqueue(.saveCurrentPage) } label: {
                Label(isSaved ? "Current Page Saved" : "Save Current Page", symbol: isSaved ? .bookmarkFill : .plus)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .disabled(isBusy || bookmarks == nil || isSaved || BrowserBookmark.normalizedURL(url) == nil)
            .accessibilityIdentifier("browser-bookmark-save")
            .padding(.horizontal)
            .padding(.vertical, 8)
            if let reason = navigationUnavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.bottom, 8)
            }
            if let error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button("Retry") { enqueue(.list) }.disabled(isBusy)
                }.padding(.horizontal).padding(.bottom, 8)
            }
            if isBusy, bookmarks == nil {
                ProgressView("Loading bookmarks…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let bookmarks, bookmarks.isEmpty {
                Text("No bookmarks yet").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(bookmarks ?? []) { bookmark in
                    VStack(alignment: .leading) {
                        Button {
                            guard navigationUnavailableReason == nil else { return }
                            navigate(bookmark.url)
                            isPresented = false
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(bookmark.title).lineLimit(2)
                                Text(URL(string: bookmark.url)?.host ?? bookmark.url)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy || navigationUnavailableReason != nil)
                        .help(bookmark.url)
                        .accessibilityIdentifier("browser-bookmark-\(bookmark.id)")
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Delete", role: .destructive) { enqueue(.remove(bookmark.id)) }
                            .disabled(isBusy)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { enqueue(.remove(bookmark.id)) }
                            .disabled(isBusy)
                    }
                }.listStyle(.plain)
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
    }

    private func enqueue(_ operation: BrowserBookmarkOperation) {
        self.operation = operation
        isBusy = true
        requestID = UUID()
    }
}
