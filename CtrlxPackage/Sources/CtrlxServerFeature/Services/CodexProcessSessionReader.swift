import Darwin
import Foundation

/// Reads only the active writer's metadata, never argv (which names the parent
/// of a fork) or a history-directory search (which can belong to another pane).
actor CodexProcessSessionReader {
    static let headerLimit = 256 * 1024
    private static let descriptorLimit = 4096

    func sessionID(processID: String, runtimeID: String) -> String? {
        guard !Task.isCancelled, let pid = Int32(processID),
              AgentSessionIdentityClient.processRuntimeID(processID) == runtimeID,
              let before = activeRollout(pid: pid),
              let header = readHeader(before),
              let id = Self.sessionID(header: header, path: before.path),
              !Task.isCancelled,
              AgentSessionIdentityClient.processRuntimeID(processID) == runtimeID,
              activeRollout(pid: pid) == before
        else { return nil }
        return id
    }

    private struct Rollout: Equatable {
        let path: String
        let device: UInt32
        let inode: UInt64
    }

    private func activeRollout(pid: Int32) -> Rollout? {
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Self.descriptorLimit)
        let capacity = descriptors.count * MemoryLayout<proc_fdinfo>.stride
        let size = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard size > 0, size < capacity, Int(size) % MemoryLayout<proc_fdinfo>.stride == 0 else { return nil }
        var result: Rollout?
        for descriptor in descriptors.prefix(Int(size) / MemoryLayout<proc_fdinfo>.stride) {
            guard descriptor.proc_fdtype == PROX_FDTYPE_VNODE else { continue }
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
                  info.pfi.fi_openflags & UInt32(FWRITE) != 0,
                  info.pvip.vip_vi.vi_stat.vst_mode & UInt16(S_IFMT) == UInt16(S_IFREG)
            else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) {
                String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8)
            }
            guard let path, Self.filenameID(path) != nil else { continue }
            let candidate = Rollout(path: path, device: info.pvip.vip_vi.vi_stat.vst_dev, inode: info.pvip.vip_vi.vi_stat.vst_ino)
            // Duplicate descriptors for one writer are fine; two writers are ambiguous.
            if let result, result != candidate { return nil }
            result = candidate
        }
        return result
    }

    private func readHeader(_ rollout: Rollout) -> Data? {
        let fd = open(rollout.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              UInt32(bitPattern: info.st_dev) == rollout.device, info.st_ino == rollout.inode
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: Self.headerLimit + 1)
        let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count > 0, let newline = bytes.prefix(count).firstIndex(of: 10), newline <= Self.headerLimit else { return nil }
        return Data(bytes[..<newline])
    }

    static func sessionID(header: Data, path: String) -> String? {
        struct Record: Decodable {
            struct Metadata: Decodable {
                let id: String
                let source: String
            }
            let type: String
            let payload: Metadata
        }
        guard header.count <= headerLimit,
              let filenameID = filenameID(path),
              let record = try? JSONDecoder().decode(Record.self, from: header),
              record.type == "session_meta", record.payload.source == "cli",
              UUID(uuidString: record.payload.id) == filenameID
        else { return nil }
        return record.payload.id
    }

    private static func filenameID(_ path: String) -> UUID? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        return UUID(uuidString: String(name.dropLast(6).suffix(36)))
    }
}
