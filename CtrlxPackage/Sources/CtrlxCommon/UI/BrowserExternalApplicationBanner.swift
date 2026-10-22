import CtrlxNetworking
import SwiftUI

/// A launch result belongs to a page, not a modal or a webpage-controlled dialog.
@MainActor
public struct BrowserExternalApplicationBanner: View {
    private let notice: BrowserExternalApplicationNotice?
    @State private var dismissedID: UUID?

    public init(notice: BrowserExternalApplicationNotice?) {
        self.notice = notice
    }

    public var body: some View {
        Group {
            if let notice, notice.id != dismissedID {
                HStack {
                    Text(notice.message).font(.caption)
                        .foregroundStyle(notice.isError ? Color.red : .secondary)
                    Spacer()
                    Button { dismissedID = notice.id } label: {
                        Label("Dismiss", symbol: .xmark)
                    }.labelStyle(.iconOnly)
                }
                .padding(8)
                .background(.regularMaterial)
                .accessibilityIdentifier("browser-external-application-result")
            }
        }
        .task(id: notice?.id) {
            guard let notice, !notice.isError else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            dismissedID = notice.id
        }
    }
}
