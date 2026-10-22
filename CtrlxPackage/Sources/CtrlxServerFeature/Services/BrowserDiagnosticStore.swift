import Darwin
import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct BrowserDiagnosticStore: Sendable {
    /// Small, synchronous breadcrumbs survive a process trap without a queued flush.
    var append: @Sendable (_ data: Data) throws -> Void
    var memory: @Sendable () -> [String: UInt64] = { [:] }
}

extension BrowserDiagnosticStore: DependencyKey {
    static let liveValue = Self(
        append: { try append($0, directory: directory()) },
        memory: {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return [:] }
            return ["residentBytes": info.resident_size, "footprintBytes": info.phys_footprint]
        }
    )
    static let testValue = Self()

    static func directory(
        arguments: [String] = CommandLine.arguments,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        if arguments.contains("--e2e-test") {
            guard let index = arguments.firstIndex(of: "--ctrlx-state-root"), index + 1 < arguments.count else {
                throw CocoaError(.fileNoSuchFile)
            }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                .appendingPathComponent("browser-diagnostics", isDirectory: true)
        }
        return home.appendingPathComponent("Library/Logs/CtrlX/Browser", isDirectory: true)
    }

    static func append(_ data: Data, directory: URL, maximumBytes: UInt64 = 2 * 1_024 * 1_024) throws {
        guard data.count < maximumBytes else { throw CocoaError(.fileWriteUnknown) }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let paths = ["current", "previous", "older"].map { directory.appendingPathComponent("browser-\($0).jsonl") }
        let output = paths[0]
        if files.fileExists(atPath: output.path) {
            let size = try (files.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.uint64Value ?? 0
            if size + UInt64(data.count) + 1 > maximumBytes {
                if files.fileExists(atPath: paths[2].path) {
                    try files.removeItem(at: paths[2])
                }
                if files.fileExists(atPath: paths[1].path) {
                    try files.moveItem(at: paths[1], to: paths[2])
                }
                try files.moveItem(at: output, to: paths[1])
            }
        }
        if !files.fileExists(atPath: output.path) {
            guard files.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data + Data([0x0A]))
    }
}
