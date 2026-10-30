#if os(macOS)
    import Darwin
    import Foundation

    /// Shared caller-evidence matching; the returned kernel name is never a launch path.
    public enum AgentExecutableIdentity {
        private static let removableNames: Set = ["codex", "codex-code-mode-host", "claude", "opencode", "omp", "pi"]

        public static func resolve(path: String?, errorCode: Int32, kernelName: String) -> String? {
            if let path, path.hasPrefix("/") {
                return path
            }
            guard errorCode == ENOENT, removableNames.contains(kernelName) else { return nil }
            return kernelName
        }

        /// An unlink can change the available evidence without changing the process.
        public static func matches(_ first: String, _ second: String) -> Bool {
            if first == second {
                return true
            }
            let name: String
            let path: String
            if first.hasPrefix("/"), !second.hasPrefix("/") {
                name = second
                path = first
            } else if second.hasPrefix("/"), !first.hasPrefix("/") {
                name = first
                path = second
            } else {
                return false
            }
            return removableNames.contains(name) && URL(fileURLWithPath: path).lastPathComponent == name
        }
    }
#endif
