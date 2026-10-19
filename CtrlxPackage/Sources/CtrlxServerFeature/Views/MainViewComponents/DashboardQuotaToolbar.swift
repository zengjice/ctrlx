import CtrlxCommon
import CtrlxNetworking
import SwiftUI

/// Only the compact controls occupy titlebar space; the native toolbar spacer owns the rest.
@MainActor
struct DashboardQuotaToolbar: View {
    let store: DashboardStore
    let openDashboard: () -> Void

    @State private var windowWidth: CGFloat = 0
    @State private var hoveredID: DashboardAccountGroup.ID?
    @State private var presentation: Presentation?

    private enum Presentation {
        case summary(DashboardAccountGroup.ID)
        case account(DashboardAccountGroup.ID)
        case overflow(Int)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            // Store updates can arrive between timer ticks; judge them against now.
            let now = Date()
            let accounts = DashboardToolbarAccount.accounts(in: store.hosts, at: now)
            ViewThatFits(in: .horizontal) {
                ForEach((0...min(4, accounts.count)).reversed(), id: \.self) { count in
                    strip(accounts: accounts, count: count)
                        .fixedSize()
                }
            }
            // AppKit treats a SwiftUI toolbar item's ideal width as fixed. Give it
            // a bounded width before it decides which native toolbar items to overflow.
            .frame(width: min(idealWidth(accounts.count), max(32, windowWidth - 800)), height: 32, alignment: .leading)
            .background(DashboardQuotaPopover(width: $windowWidth, isPresented: Binding(
                get: { presentation != nil },
                set: {
                    if !$0 {
                        presentation = nil
                    }
                }
            )) {
                popover(accounts: accounts, at: now)
                    .padding(16)
                    .frame(width: 340)
            })
            .task(id: hoveredID) {
                if case .account = presentation {
                    return
                }
                if case .overflow = presentation {
                    return
                }
                presentation = nil
                guard let hoveredID else {
                    return
                }
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                guard case nil = presentation else { return }
                presentation = .summary(hoveredID)
            }
        }
    }

    private func idealWidth(_ total: Int) -> CGFloat {
        CGFloat(max(1, min(total, 4) + (total > 4 ? 1 : 0)) * 38 - 6)
    }

    private func strip(accounts: [DashboardToolbarAccount], count: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(accounts.prefix(count)) { item in
                Button { presentation = .account(item.id) } label: {
                    DashboardQuotaRing(item: item)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityValue(item.remaining.map { "\(Int($0))% remaining" } ?? "Quota unavailable")
                .accessibilityIdentifier("dashboard-quota-\(item.account.id)")
                .onHover { inside in
                    if inside {
                        hoveredID = item.id
                    } else if hoveredID == item.id {
                        hoveredID = nil
                    }
                }
            }
            if count < accounts.count || accounts.isEmpty {
                Button { presentation = .overflow(count) } label: {
                    Group {
                        if count == 0 {
                            Symbols.gaugeWithDotsNeedle50percent.image
                        } else {
                            Text("+\(accounts.count - count)").font(.caption.monospacedDigit())
                        }
                    }
                    .frame(minWidth: 32, minHeight: 32)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("More account quotas")
                .accessibilityLabel("More account quotas")
                .accessibilityIdentifier("dashboard-quota-overflow")
            }
        }
    }

    @ViewBuilder
    private func popover(accounts: [DashboardToolbarAccount], at now: Date) -> some View {
        switch presentation {
        case let .summary(id),
             let .account(id):
            if let item = accounts.first(where: { $0.id == id }) {
                DashboardQuotaCard(item: item, at: now, compact: isSummary) {
                    presentation = nil
                    openDashboard()
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(isSummary ? "dashboard-quota-summary" : "dashboard-quota-detail")
            } else {
                Text("Account no longer available")
            }
        case let .overflow(start):
            VStack(alignment: .leading, spacing: 12) {
                Text("Account quotas").font(.headline)
                if accounts.isEmpty {
                    Text(store.isRefreshing ? "Reading account information…" : "Account information unavailable")
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(accounts.dropFirst(min(start, accounts.count))) { item in
                            Button { presentation = .account(item.id) } label: {
                                HStack(spacing: 10) {
                                    DashboardQuotaRing(item: item)
                                    VStack(alignment: .leading) {
                                        Text(item.account.providerName).font(.headline)
                                        Text(item.account.label).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(item.remaining.map { "\(Int($0))%" } ?? "—").monospacedDigit()
                                }
                                .padding(6)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("dashboard-quota-list-\(item.account.id)")
                        }
                    }
                }
                .frame(maxHeight: 280)
                Button("Open Dashboard") { presentation = nil
                    openDashboard()
                }
            }
        case nil:
            EmptyView()
        }
    }

    private var isSummary: Bool {
        if case .summary = presentation {
            return true
        }
        return false
    }
}

private struct DashboardQuotaRing: View {
    let item: DashboardToolbarAccount

    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.2), lineWidth: 2.5)
            if let remaining = item.remaining {
                if remaining == 0 {
                    Circle().stroke(.red, lineWidth: 2.5)
                } else {
                    Circle().trim(from: 0, to: remaining / 100)
                        .stroke(item.level.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            } else {
                Circle().stroke(.secondary, style: StrokeStyle(lineWidth: 2, dash: [2, 3]))
            }
            if item.account.pluginID == "codex" || item.account.pluginID == "claude-code" {
                Image(item.account.pluginID == "codex" ? "quota-openai" : "quota-claude", bundle: .module)
                    .resizable().scaledToFit().frame(width: 18, height: 18)
            } else {
                Text(String(item.account.providerName.prefix(1)))
                    .font(.caption.bold())
            }
        }
        .frame(width: 28, height: 28)
    }
}

private struct DashboardQuotaCard: View {
    let item: DashboardToolbarAccount
    let at: Date
    let compact: Bool
    let openDashboard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                DashboardQuotaRing(item: item)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.account.providerName).font(.headline)
                    Text(item.account.label).font(.subheadline).textSelection(.enabled)
                }
            }
            if let status = item.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(item.account.windows) { window in
                let remaining = window.remainingPercent(at: at)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(window.title)
                        Spacer()
                        Text(remaining.map { "\(Int($0))% remaining" } ?? "Waiting for update")
                            .monospacedDigit()
                    }
                    if !compact {
                        if let remaining {
                            ProgressView(value: remaining, total: 100)
                                .tint(item.remaining == nil ? .secondary : item.level.color)
                        }
                        if let reset = window.resetsAt {
                            Text(reset > at ? "Resets \(reset.formatted(.relative(presentation: .named)))" : "Reset passed · Waiting for update")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.subheadline)
            }
            if !compact {
                if let credits = item.account.credits {
                    Text(credits.unlimited ? "Extra credits: unlimited" : "Extra credits: \(credits.balance ?? "unavailable")")
                        .font(.caption)
                }
                Divider()
                ForEach(item.group.sources.indices, id: \.self) { index in
                    let source = item.group.sources[index]
                    HStack {
                        Text(source.host.name)
                        Spacer()
                        Text(source.host.isConnected ? "Online" : "Offline")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let date = item.observedAt {
                Text("Last observed \(date.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !compact {
                Button("Open Dashboard", action: openDashboard)
            }
        }
    }
}

private extension DashboardToolbarAccount.Level {
    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .low: .red
        case .unknown: .secondary
        }
    }
}
