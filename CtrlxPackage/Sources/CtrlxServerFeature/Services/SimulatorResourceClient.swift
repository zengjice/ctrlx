#if os(macOS)
    import CtrlxSimulatorProtocol
    import Darwin
    import Dependencies
    import DependenciesMacros
    import Foundation

    @DependencyClient
    struct SimulatorResourceClient: Sendable {
        var read: @Sendable (URL) throws -> SimulatorResources
    }

    extension SimulatorResourceClient: DependencyKey {
        static let testValue = Self()
        static let liveValue = Self(read: { directory in
            var pressure: Int32 = 0
            var pressureSize = MemoryLayout.size(ofValue: pressure)
            var swap = xsw_usage()
            var swapSize = MemoryLayout.size(ofValue: swap)
            guard sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0) == 0,
                sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
            else { throw SimulatorFailure("Cannot read system memory pressure") }
            let host = mach_host_self()
            defer { mach_port_deallocate(mach_task_self_, host) }
            var stats = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &stats) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(host, HOST_VM_INFO64, $0, &count)
                }
            }
            var disk = statfs()
            var pageSize: vm_size_t = 0
            guard status == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS, statfs(directory.path, &disk) == 0 else {
                throw SimulatorFailure("Cannot read simulator memory or disk capacity")
            }
            return SimulatorResources(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                reclaimableBytes: (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * UInt64(pageSize),
                pressureLevel: Int(pressure), swapUsedBytes: swap.xsu_used,
                freeDiskBytes: UInt64(disk.f_bavail) * UInt64(disk.f_bsize))
        })
    }
#endif
