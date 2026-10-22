#if os(macOS)
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    struct DashboardResourceTests {
        private let memory = DashboardMemory(totalBytes: 32, usedBytes: 24, compressedBytes: 2, swapBytes: 0, pressure: .normal)

        @Test
        func cpuUsesWholeMachineDeltaAndCounterWrap() {
            #expect(DashboardResourceSampler.cpuPercent(previous: nil, current: [1, 1, 1, 1]) == nil)
            #expect(DashboardResourceSampler.cpuPercent(previous: [0, 0, 0, 0], current: [10, 10, 80, 0]) == 20)
            #expect(DashboardResourceSampler.cpuPercent(previous: [1, 1, 1, 1], current: [1, 1, 1, 1]) == nil)
            #expect(DashboardResourceSampler.cpuPercent(previous: [UInt32.max, 0, 0, 0], current: [9, 0, 90, 0]) == 10)
        }

        @Test
        func multipleViewersShareSamplingAndVolumesAreDeduplicated() async throws {
            let counters = Counters()
            let memory = memory
            try await withDependencies {
                $0[HostResourceClient.self].cpuTicks = {
                    let count = await counters.cpu()
                    return [UInt32(count * 10), 0, UInt32(count * 90), 0]
                }
                $0[HostResourceClient.self].memory = { memory }
                $0[HostResourceClient.self].disk = { _ in
                    await counters.disk()
                    return .init(id: "volume", name: "System", totalBytes: 100, availableBytes: 20)
                }
            } operation: {
                let sampler = DashboardResourceSampler()
                let date = Date(timeIntervalSince1970: 1_000)
                await withTaskGroup(of: DashboardResources.self) { group in
                    for _ in 0..<6 {
                        group.addTask { await sampler.read(paths: ["/project", "/project"], at: date) }
                    }
                    for await result in group {
                        #expect(result.memory == memory)
                    }
                }
                let first = try await diskSample(sampler, paths: ["/project"], at: date)
                #expect(first.disks.count == 1)
                #expect(await counters.cpuCalls == 1)
                #expect(await counters.diskCalls == 2)
                let second = await sampler.read(paths: ["/project"], at: date.addingTimeInterval(5))
                #expect(second.cpuPercent == 10)
                #expect(await counters.cpuCalls == 2)
                #expect(await counters.diskCalls == 2)
                _ = try await diskSample(sampler, paths: ["/project"], at: date.addingTimeInterval(61))
                #expect(await counters.diskCalls == 4)
            }
        }

        @Test
        func partialFailureDoesNotInventZeroOrHideOtherResources() async throws {
            try await withDependencies {
                $0[HostResourceClient.self].cpuTicks = { throw CocoaError(.featureUnsupported) }
                $0[HostResourceClient.self].memory = { throw CocoaError(.featureUnsupported) }
                $0[HostResourceClient.self].disk = { path in
                    guard path == "/" else { throw CocoaError(.fileReadUnknown) }
                    return .init(id: "system", name: "System", totalBytes: 100, availableBytes: 20)
                }
            } operation: {
                let sample = try await diskSample(DashboardResourceSampler(), paths: ["/unmounted/project"], at: Date())
                #expect(sample.cpuPercent == nil)
                #expect(sample.memory == nil)
                #expect(sample.disks.count == 1)
                #expect(sample.issues.count == 3)
            }
        }

        @Test
        func stalledDiskRefreshKeepsCachedDisksWithoutBlockingOrDuplicatingWork() async throws {
            let gate = DiskGate()
            let counters = Counters()
            let memory = memory
            // Release even if a regression blocks read(), so the suite can report failure.
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                await gate.release()
            }
            defer { watchdog.cancel() }
            try await withDependencies {
                $0[HostResourceClient.self].cpuTicks = {
                    let count = await counters.cpu()
                    return [UInt32(count * 10), 0, UInt32(count * 90), 0]
                }
                $0[HostResourceClient.self].memory = { memory }
                $0[HostResourceClient.self].disk = { _ in
                    let count = await gate.read()
                    return .init(id: "volume", name: "System", totalBytes: 100, availableBytes: UInt64(count * 10))
                }
            } operation: {
                let sampler = DashboardResourceSampler()
                let date = Date(timeIntervalSince1970: 1_000)
                let first = try await diskSample(sampler, paths: [], at: date)
                let refreshDate = date.addingTimeInterval(61)
                for index in 0..<8 {
                    let snapshot = await sampler.read(paths: [], at: refreshDate.addingTimeInterval(Double(index * 5)))
                    #expect(snapshot.memory == memory)
                    if index > 0 {
                        #expect(snapshot.cpuPercent == 10)
                    }
                    #expect(snapshot.disks == first.disks)
                    #expect(snapshot.disksObservedAt == date)
                }
                let cancelled = Task { await sampler.read(paths: ["/another-project"], at: refreshDate) }
                cancelled.cancel()
                _ = await cancelled.value
                #expect(await gate.released == false)
                await gate.release()
                let refreshed = try await diskSample(sampler, paths: [], at: refreshDate)
                #expect(refreshed.disks.first?.availableBytes == 20)
                #expect(refreshed.issues["disk"] == nil)
                #expect(await gate.calls == 2)
            }
        }

        private func diskSample(_ sampler: DashboardResourceSampler, paths: [String], at date: Date) async throws -> DashboardResources {
            for _ in 0..<200 {
                let result = await sampler.read(paths: paths, at: date)
                if result.disksObservedAt == date {
                    return result
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw CocoaError(.fileReadUnknown)
        }

        private actor DiskGate {
            var calls = 0
            var released = false
            private var continuation: CheckedContinuation<Void, Never>?

            func read() async -> Int {
                calls += 1
                let count = calls
                if count > 1, !released {
                    await withCheckedContinuation { continuation = $0 }
                }
                return count
            }

            func release() {
                released = true
                continuation?.resume()
                continuation = nil
            }
        }

        @Test
        func nativeResourceReadHasValidUnits() async throws {
            let client = HostResourceClient.liveValue
            let memory = try await client.memory()
            #expect(memory.totalBytes > 0)
            #expect(memory.usedBytes <= memory.totalBytes)
            let disk = try await client.disk(FileManager.default.homeDirectoryForCurrentUser.path)
            #expect(disk.totalBytes > 0)
            #expect(disk.availableBytes <= disk.totalBytes)
            let first = try await client.cpuTicks()
            try await Task.sleep(for: .milliseconds(50))
            let next = try await client.cpuTicks()
            #expect(first.count == 4 && next.count == 4)
            let percent = DashboardResourceSampler.cpuPercent(previous: first, current: next)
            if first == next {
                #expect(percent == nil)
            } else {
                #expect(try (0...100).contains(#require(percent)))
            }
        }

        private actor Counters {
            var cpuCalls = 0
            var diskCalls = 0
            func cpu() -> Int {
                cpuCalls += 1
                return cpuCalls
            }

            func disk() {
                diskCalls += 1
            }
        }
    }
#endif
