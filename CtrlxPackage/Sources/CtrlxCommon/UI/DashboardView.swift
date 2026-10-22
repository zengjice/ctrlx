import CtrlxNetworking
import SwiftUI

public struct DashboardSessionLink: Identifiable {
    public var id: String
    public var title: String
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Both clients render the same account, resource and usage semantics.
@MainActor
public struct DashboardView: View {
    private let endpoints: @MainActor () -> [DashboardEndpoint]
    private let sessions: @MainActor (String) -> [DashboardSessionLink]
    private let openSession: @MainActor (String, String) -> Void
    private let close: (@MainActor () -> Void)?
    private let store: DashboardStore
    @State private var path: [String] = []
    @Environment(\.scenePhase) private var scenePhase

    public init(
        store: DashboardStore,
        endpoints: @escaping @MainActor () -> [DashboardEndpoint],
        sessions: @escaping @MainActor (String) -> [DashboardSessionLink] = { _ in [] },
        openSession: @escaping @MainActor (String, String) -> Void = { _, _ in },
        close: (@MainActor () -> Void)? = nil
    ) {
        self.store = store
        self.endpoints = endpoints
        self.sessions = sessions
        self.openSession = openSession
        self.close = close
    }

    private var hosts: [DashboardHost] {
        DashboardOverview.uniqueHosts(store.hosts)
    }

    public var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Accounts") {
                    let accounts = DashboardOverview.accounts(in: hosts)
                    if accounts.isEmpty {
                        Text("Account information appears when a supported Host is reachable.").foregroundStyle(.secondary)
                    }
                    ForEach(accounts) { account in DashboardAccountRow(group: account) }
                }
                Section {
                    Toggle("Low quota alerts", isOn: Binding(get: { store.lowQuotaAlertsEnabled }, set: { store.lowQuotaAlertsEnabled = $0 }))
                    if let error = store.notificationError {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Alerts at 10% remaining. On iPhone, checks only while the app is open.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("Hosts") {
                    ForEach(hosts) { host in
                        NavigationLink(value: host.id) { DashboardHostSummary(host: host) }
                    }
                    if hosts.isEmpty {
                        Text("No Hosts paired").foregroundStyle(.secondary)
                    }
                }
                Section("Today · observed by CtrlX") {
                    let usage = DashboardOverview.usage(in: hosts, at: Date())
                    if hosts.contains(where: { $0.currentUsage(at: Date()) != nil }) {
                        LabeledContent("Tokens", value: usage.tokens.formatted(.number.notation(.compactName)))
                        LabeledContent("Sessions", value: usage.sessions.formatted())
                    } else {
                        Text("Waiting for usage data").foregroundStyle(.secondary)
                    }
                    Text("\(usage.currentHosts) / \(hosts.count) Hosts updated · each Host’s local date")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Last 7 days and projects") {
                        ForEach(hosts) { host in
                            DisclosureGroup(host.name) { DashboardUsageDetail(host: host) }
                        }
                        Text("Observed tokens exclude cache reads and writes. This is not an account bill.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = store.cacheError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Dashboard")
            .navigationDestination(for: String.self) { id in
                if let host = hosts.first(where: { $0.id == id }) {
                    hostDetail(host)
                } else {
                    Text("This Host is no longer available.")
                }
            }
            .toolbar {
                if let close {
                    ToolbarItem(placement: .cancellationAction) { Button("Done", action: close) }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await store.refresh(endpoints()) }
                    } label: { Label("Refresh", symbol: .arrowClockwise) }
                        .disabled(store.isRefreshing)
                        .accessibilityIdentifier("dashboard-refresh")
                }
            }
            .overlay {
                if store.hosts.isEmpty && store.isRefreshing {
                    ProgressView()
                }
            }
            .refreshable { await store.refresh(endpoints()) }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.refresh(endpoints())
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
        .accessibilityIdentifier("dashboard")
    }

    private func hostDetail(_ host: DashboardHost) -> some View {
        List {
            Section {
                Picker("Host", selection: Binding(get: { host.id }, set: { path = [$0] })) {
                    ForEach(hosts) { item in Text(item.name).tag(item.id) }
                }
                DashboardHostSummary(host: host)
            }
            Section("Resources") {
                if let resources = host.snapshot?.resources {
                    LabeledContent("CPU", value: resources.cpuPercent.map { $0.formatted(.number.precision(.fractionLength(0))) + "%" } ?? "Waiting for sample")
                    if let memory = resources.memory {
                        LabeledContent("Memory", value: "\(dashboardBytes(memory.usedBytes)) / \(dashboardBytes(memory.totalBytes))")
                        LabeledContent("Pressure", value: memory.pressure.rawValue.capitalized)
                        LabeledContent("Compressed", value: dashboardBytes(memory.compressedBytes))
                        LabeledContent("Swap", value: dashboardBytes(memory.swapBytes))
                    }
                    ForEach(resources.disks) { disk in
                        LabeledContent(disk.name, value: "\(dashboardBytes(disk.availableBytes)) free / \(dashboardBytes(disk.totalBytes))")
                    }
                    if let date = resources.disksObservedAt {
                        Text("Disk sample: \(date.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(resources.issues.keys.sorted(), id: \.self) { key in
                        Text(resources.issues[key] ?? "").font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text("Resource information is unavailable.").foregroundStyle(.secondary)
                }
            }
            Section("Accounts · shared quotas") {
                ForEach(DashboardOverview.accounts(in: hosts).filter { $0.sources.contains(where: { $0.host.id == host.id }) }) { group in
                    DashboardAccountRow(group: group)
                }
            }
            Section("Observed usage") { DashboardUsageDetail(host: host) }
            Section("Sessions") {
                let links = sessions(host.id)
                ForEach(links) { session in
                    Button(session.title) { openSession(host.id, session.id) }.disabled(!host.isConnected)
                }
                if links.isEmpty {
                    Text("No sessions available").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(host.name)
    }
}

@MainActor
private struct DashboardAccountRow: View {
    let group: DashboardAccountGroup

    var body: some View {
        if let selected = group.selection {
            let source = selected.source
            let account = source.account
            DisclosureGroup {
                ForEach(Array(group.sources.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(item.host.name) · \(item.account.configurationLabel)").font(.headline)
                        Text(authentication(item.account.authentication)).foregroundStyle(.secondary)
                        if item.account.identity == nil {
                            Text("Account identity unconfirmed; shown separately.").font(.caption).foregroundStyle(.secondary)
                        }
                        quotaLines(item, all: true)
                        if let detail = item.account.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                        if let observed = item.account.quotaObservedAt {
                            Text("Source observation: \(observed.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary)
                        }
                        if let credits = item.account.credits {
                            LabeledContent("Additional credits", value: credits.unlimited ? "Unlimited" : (credits.balance ?? "Not provided"))
                        }
                        if !item.host.isConnected {
                            Text("Offline · last observation").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(account.providerName) · \(account.label)").font(.headline)
                    if account.availability == .available, let detail = account.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    quotaLines(source, all: false)
                    Text(Array(Set(group.sources.map(\.host.name))).sorted().joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                    if account.windows.count > 2 {
                        Text("Additional quota limits · expand to view").font(.caption).foregroundStyle(.secondary)
                    }
                    if account.limitReached == true || account.windows.contains(where: { $0.remainingPercent(at: Date()) == 0 }) {
                        Text("A quota limit has been reached").font(.caption).foregroundStyle(.orange)
                    }
                    if selected.uncertain {
                        Text("Sources differ; expand to compare observations.").font(.caption).foregroundStyle(.orange)
                    }
                    if account.availability == .failed || !source.host.isConnected {
                        Text("Last observation · refresh unavailable").font(.caption).foregroundStyle(.secondary)
                    } else if let interval = source.interval, Date().timeIntervalSince(interval.upperBound) > 300 {
                        Text("Last observed \(interval.upperBound, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("dashboard-account")
        }
    }

    @ViewBuilder
    private func quotaLines(_ source: DashboardAccountGroup.Source, all: Bool) -> some View {
        let windows = all ? source.account.windows : Array(source.account.windows.prefix(2))
        if windows.isEmpty {
            Text(source.account.detail ?? availability(source.account.availability)).font(.subheadline).foregroundStyle(.secondary)
        }
        ForEach(windows) { window in
            let remaining = window.remainingPercent(at: Date())
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(window.title)
                    Spacer(minLength: 4)
                    Text(remaining.map { "\($0.formatted(.number.precision(.fractionLength(0))))% remaining" } ?? "Waiting for update")
                        .monospacedDigit()
                }
                .font(.subheadline)
                if let remaining {
                    ProgressView(value: remaining, total: 100).tint(remaining <= 10 ? .orange : .accentColor)
                }
                if let reset = window.resetsAt, reset > Date() {
                    let delta = reset.timeIntervalSinceNow
                    Text("Resets in \(Duration.seconds(delta).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func authentication(_ value: DashboardAccount.Authentication) -> String {
        switch value {
        case .signedIn: "Signed in"
        case .signedOut: "Sign in on this Host"
        case .unknown: "Sign-in state unavailable"
        }
    }

    private func availability(_ value: DashboardAccount.Availability) -> String {
        switch value {
        case .available: "No primary quota window"
        case .waiting: "Waiting for first quota observation"
        case .unsupported: "Quotas unavailable for this source"
        case .failed: "Could not read quotas"
        }
    }
}

@MainActor
private struct DashboardHostSummary: View {
    let host: DashboardHost

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(host.name).font(.headline)
                Spacer()
                Text(host.isConnected ? "Online" : "Offline").font(.caption).foregroundStyle(host.isConnected ? .green : .secondary)
            }
            if host.isConnected && !host.isSupported {
                Text("Update the Host to view Dashboard data.").font(.caption).foregroundStyle(.secondary)
            }
            if let count = host.snapshot?.workingAgentCount, host.isConnected {
                Text("\(count) Agents working").font(.caption).foregroundStyle(.secondary)
            }
            if let memory = host.snapshot?.resources?.memory {
                Text("Memory \(dashboardBytes(memory.usedBytes)) / \(dashboardBytes(memory.totalBytes)) · \(memory.pressure.rawValue)")
                    .font(.subheadline).foregroundStyle(memory.pressure == .critical || memory.pressure == .warning ? .orange : .secondary)
            }
            if let disk = host.snapshot?.resources?.disks.min(by: { $0.availableBytes < $1.availableBytes }) {
                Text("\(disk.name) · \(dashboardBytes(disk.availableBytes)) free")
                    .font(.subheadline).foregroundStyle(disk.availableBytes < 20 * 1_024 * 1_024 * 1_024 ? .orange : .secondary)
            }
            if let received = host.receivedAt {
                Text("Received \(received, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
            }
            if let error = host.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dashboard-host-\(host.id)")
    }
}

@MainActor
private struct DashboardUsageDetail: View {
    let host: DashboardHost

    var body: some View {
        if let usage = host.snapshot?.usage ?? host.legacyUsage {
            Text("\(usage.generatedDay) · \(host.snapshot?.timeZoneIdentifier ?? "")")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Observed tokens", value: usage.todayTokens.formatted())
            LabeledContent("Sessions", value: usage.todaySessionCount.formatted())
            if host.snapshot == nil {
                Text("Host time zone and sample time unavailable; excluded from today’s total.").font(.caption).foregroundStyle(.secondary)
            } else if host.currentUsage(at: Date()) == nil {
                Text("Saved date; excluded from today’s total.").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Daily tokens · last 7 days") {
                let maximum = max(1, usage.days.map(\.tokens).max() ?? 1)
                ForEach(usage.days) { day in
                    VStack(alignment: .leading) {
                        LabeledContent(day.day, value: day.tokens.formatted(.number.notation(.compactName)))
                        ProgressView(value: Double(day.tokens), total: Double(maximum))
                    }
                }
            }
            DisclosureGroup("Projects · last 7 days") {
                ForEach(usage.projects) { project in
                    VStack(alignment: .leading) {
                        LabeledContent(project.projectName, value: project.tokens.formatted(.number.notation(.compactName)))
                        Text(project.projectPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        } else {
            Text("Usage has not been provided.").foregroundStyle(.secondary)
        }
    }
}

private func dashboardBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
}
