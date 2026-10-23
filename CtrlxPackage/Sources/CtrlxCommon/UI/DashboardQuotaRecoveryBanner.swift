import SwiftUI

/// Unread quota recoveries stay visible across Dashboard refreshes until the
/// account's notice is marked read or the account disappears from every Host.
@MainActor
public struct DashboardQuotaRecoveryBanner: View {
    private let store: DashboardStore

    public init(store: DashboardStore) {
        self.store = store
    }

    public var body: some View {
        if !store.quotaRecoveryNotices.isEmpty {
            VStack(spacing: 0) {
                ForEach(store.quotaRecoveryNotices) { notice in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Symbols.checkmarkCircle.image
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Quota recovered for \(notice.account)")
                            Text(notice.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Mark as Read") { store.markQuotaRecoveryRead(notice.id) }
                    }
                    .font(.callout)
                    .padding(10)
                    .accessibilityIdentifier("dashboardQuotaRecoveryBanner-\(notice.id)")
                    if notice.id != store.quotaRecoveryNotices.last?.id {
                        Divider()
                    }
                }
            }
            .background(.regularMaterial)
        }
    }
}
