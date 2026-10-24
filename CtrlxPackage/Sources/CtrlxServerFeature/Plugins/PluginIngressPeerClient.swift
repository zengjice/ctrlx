#if os(macOS)
    import CtrlxPluginProtocol
    import Darwin
    import Dependencies
    import DependenciesMacros

    @DependencyClient
    struct PluginIngressPeerClient: Sendable {
        var capture: @Sendable (_ socketFD: Int32) -> PluginIngressPeer? = { _ in nil }
    }

    extension PluginIngressPeerClient: DependencyKey {
        static let testValue = Self(capture: { _ in nil })
        static let liveValue = Self(capture: { fd in
            var pid: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: pid))
            guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 1 else { return nil }
            return PluginIngressPeer.capture(peerPID: pid, userID: getuid(), inspect: inspect)
        })

        private static func inspect(_ pid: Int32) -> PluginIngressPeer.Process? {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
            return .init(
                processID: pid, parentProcessID: Int32(info.pbi_ppid), userID: info.pbi_uid,
                startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec
            )
        }
    }
#endif
