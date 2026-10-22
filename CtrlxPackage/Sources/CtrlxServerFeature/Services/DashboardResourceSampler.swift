#if os(macOS)
    import CtrlxNetworking
    import Darwin
    import Dependencies
    import DependenciesMacros
    import Foundation

    @DependencyClient
    struct HostResourceClient: Sendable {
        var cpuTicks: @Sendable () async throws -> [UInt32]
        var memory: @Sendable () async throws -> DashboardMemory
        var disk: @Sendable (_ path: String) async throws -> DashboardDisk
    }

    extension HostResourceClient: DependencyKey {
        static let liveValue = Self(
            cpuTicks: {
                try await Task.detached {
                    let host = mach_host_self()
                    defer { mach_port_deallocate(mach_task_self_, host) }
                    var info = host_cpu_load_info()
                    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
                    let status = withUnsafeMutablePointer(to: &info) {
                        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                            host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
                        }
                    }
                    guard status == KERN_SUCCESS else { throw CocoaError(.featureUnsupported) }
                    return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
                }.value
            },
            memory: {
                try await Task.detached {
                    let host = mach_host_self()
                    defer { mach_port_deallocate(mach_task_self_, host) }
                    var stats = vm_statistics64()
                    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: stats) / MemoryLayout<integer_t>.size)
                    let status = withUnsafeMutablePointer(to: &stats) {
                        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                            host_statistics64(host, HOST_VM_INFO64, $0, &count)
                        }
                    }
                    var page: vm_size_t = 0
                    var pressure: Int32 = 0
                    var pressureSize = MemoryLayout.size(ofValue: pressure)
                    var swap = xsw_usage()
                    var swapSize = MemoryLayout.size(ofValue: swap)
                    guard
                        status == KERN_SUCCESS,
                        host_page_size(host, &page) == KERN_SUCCESS,
                        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0,
                        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 else { throw CocoaError(.featureUnsupported) }
                    let resident = UInt64(stats.internal_page_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
                    let purgeable = UInt64(stats.purgeable_count)
                    let used = (resident - min(resident, purgeable)) * UInt64(page)
                    let total = ProcessInfo.processInfo.physicalMemory
                    let level: DashboardMemory.Pressure = switch pressure {
                    case 1: .normal
                    case 2: .warning
                    case 4: .critical
                    default: .unknown
                    }
                    return DashboardMemory(
                        totalBytes: total,
                        usedBytes: min(total, used),
                        compressedBytes: UInt64(stats.compressor_page_count) * UInt64(page),
                        swapBytes: swap.xsu_used,
                        pressure: level
                    )
                }.value
            },
            disk: { path in
                try await Task.detached {
                    var disk = statfs()
                    guard statfs(path, &disk) == 0 else { throw CocoaError(.fileReadUnknown) }
                    let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeNameKey])
                    return DashboardDisk(
                        id: "\(disk.f_fsid.val.0):\(disk.f_fsid.val.1)",
                        name: values.volumeName ?? path,
                        totalBytes: UInt64(disk.f_blocks) * UInt64(disk.f_bsize),
                        availableBytes: UInt64(disk.f_bavail) * UInt64(disk.f_bsize)
                    )
                }.value
            }
        )
    }

    /// Viewers share CPU/memory samples and a separate disk refresh. A blocked
    /// filesystem call may outlive its request, but never holds up a snapshot.
    actor DashboardResourceSampler {
        @Dependency(HostResourceClient.self) private var client
        private var cached: DashboardResources?
        private var previousTicks: [UInt32]?
        private var diskPaths: Set<String> = []
        private var inFlight: Task<(DashboardResources, [UInt32]?), Never>?
        private var disks: [DashboardDisk] = []
        private var disksObservedAt: Date?
        private var diskIssue: String?
        private var diskQueriedAt: Date?
        private var diskInFlight: Task<Void, Never>?

        func read(paths: [String], at date: Date) async -> DashboardResources {
            refreshDisksIfNeeded(paths: Set(paths.filter { $0.hasPrefix("/") }).union(["/"]), at: date)
            if let inFlight {
                return includingDisks(in: await inFlight.value.0)
            }
            if
                let cached, date.timeIntervalSince(cached.observedAt) >= 0,
                date.timeIntervalSince(cached.observedAt) < 5 {
                return includingDisks(in: cached)
            }
            let client = client
            // Reopening after a long pause must not show an average over the idle period.
            let previousTicks = cached.flatMap { previous in
                date >= previous.observedAt && date.timeIntervalSince(previous.observedAt) <= 30 ? self.previousTicks : nil
            }
            let task = Task {
                var snapshot = DashboardResources(observedAt: date)
                var ticks: [UInt32]?
                do {
                    ticks = try await client.cpuTicks()
                    snapshot.cpuPercent = Self.cpuPercent(previous: previousTicks, current: ticks)
                } catch { snapshot.issues["cpu"] = "CPU information is unavailable." }
                do { snapshot.memory = try await client.memory() }
                catch { snapshot.issues["memory"] = "Memory information is unavailable." }
                return (snapshot, ticks)
            }
            inFlight = task
            let (snapshot, ticks) = await task.value
            inFlight = nil
            cached = snapshot
            self.previousTicks = ticks
            return includingDisks(in: snapshot)
        }

        private func includingDisks(in resources: DashboardResources) -> DashboardResources {
            var resources = resources
            resources.disks = disks
            resources.disksObservedAt = disksObservedAt
            resources.issues["disk"] = diskIssue
            return resources
        }

        private func refreshDisksIfNeeded(paths: Set<String>, at date: Date) {
            guard diskInFlight == nil else { return }
            guard paths != diskPaths || diskQueriedAt.map({ date < $0 || date.timeIntervalSince($0) >= 60 }) ?? true else { return }
            diskPaths = paths
            diskQueriedAt = date
            diskIssue = disksObservedAt == nil ? "Reading disk information…" : "Refreshing disk information. Showing the last observation."
            let client = client
            // Do not race statfs against a timeout: cancellation cannot interrupt it.
            // Keep one refresh until it finishes instead of accumulating blocked tasks.
            diskInFlight = Task {
                var sampled: [DashboardDisk] = []
                var identities: Set<String> = []
                var issue: String?
                for path in paths.sorted() {
                    do {
                        let disk = try await client.disk(path)
                        if identities.insert(disk.id).inserted {
                            sampled.append(disk)
                        }
                    } catch { issue = "Some volumes could not be read." }
                }
                if !sampled.isEmpty {
                    disks = sampled
                    disksObservedAt = date
                }
                diskIssue = issue
                diskInFlight = nil
            }
        }

        static func cpuPercent(previous: [UInt32]?, current: [UInt32]?) -> Double? {
            guard let previous, let current, previous.count == 4, current.count == 4 else { return nil }
            let deltas = zip(current, previous).map { UInt64($0 &- $1) }
            let total = deltas.reduce(0, +)
            guard total > 0 else { return nil }
            return 100 * Double(total - deltas[2]) / Double(total)
        }
    }
#endif
