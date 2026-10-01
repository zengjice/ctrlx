import Darwin
import Foundation

/// Batch output paths belong to CtrlX, never the upstream command parser.
struct AgentBrowserBatchStep: Codable, Equatable, Sendable {
    let command: [String]
    let output: String?
}

enum AgentBrowserBatch {
    static func decode(_ data: Data) throws -> [AgentBrowserBatchStep] {
        guard data.count <= 65536 else { throw AgentBrowserTransport.Failure("Batch JSON exceeds 64 KiB.") }
        let decoder = JSONDecoder()
        let steps: [AgentBrowserBatchStep]
        if let words = try? decoder.decode([[String]].self, from: data) {
            steps = words.map { AgentBrowserBatchStep(command: $0, output: nil) }
        } else {
            steps = try decoder.decode([AgentBrowserBatchStep].self, from: data)
        }
        try validate(steps)
        return steps
    }

    static func validate(_ steps: [AgentBrowserBatchStep]) throws {
        guard !steps.isEmpty, steps.count <= 32,
              steps.flatMap(\.command).reduce(0, { $0 + $1.utf8.count }) <= 48000 else {
            throw AgentBrowserTransport.Failure("Batch requires 1...32 commands and at most 48 KB of arguments.")
        }
        var paths = Set<String>()
        for step in steps {
            try AgentBrowserPageCommand.validate(step.command)
            guard (AgentBrowserPageCommand.artifactExtension(step.command) != nil) == (step.output != nil) else {
                throw AgentBrowserTransport.Failure("Artifact steps require output; non-artifact steps must omit it.")
            }
            if let output = step.output {
                guard !output.isEmpty, !output.contains("\0"), output.utf8.count < 4096 else {
                    throw AgentBrowserTransport.Failure("Invalid batch output path.")
                }
                let path = URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath().path
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
                let caseSensitive = try parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames ?? true
                guard paths.insert(caseSensitive ? path : path.lowercased()).inserted else { throw AgentBrowserTransport.Failure("Batch output paths must be distinct.") }
                var info = stat()
                guard lstat(output, &info) != 0, errno == ENOENT else {
                    throw AgentBrowserTransport.Failure("Batch output already exists or cannot be inspected; no page action sent.")
                }
                guard (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    throw AgentBrowserTransport.Failure("Batch output parent must already exist.")
                }
            }
        }
    }

    static func export(_ result: Any, to output: String?) throws -> Any {
        guard let output, (result as? [String: Any])?["artifactSkipped"] as? Bool != true else { return result }
        guard var body = result as? [String: Any], let encoded = body.removeValue(forKey: "data") as? String,
              let data = Data(base64Encoded: encoded), data.count <= 6 * 1024 * 1024 else {
            throw AgentBrowserTransport.Failure("Invalid or oversized engine artifact.")
        }
        let fd = Darwin.open(output, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentBrowserTransport.Failure("Output exists or cannot be created; page action may have completed. Not retried.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        body["path"] = output; body["bytes"] = data.count
        return body
    }

    static func execute(_ steps: [AgentBrowserBatchStep], continueOnError: Bool,
                        perform: ([String]) throws -> Any) throws -> [[String: Any]] {
        try validate(steps) // Complete validation before the first page action.
        var results: [[String: Any]] = []
        for (index, step) in steps.enumerated() {
            do {
                let result = try export(perform(step.command), to: step.output)
                results.append(["index": index, "success": true, "result": result])
            } catch {
                // Upstream errors may contain credentials/URLs. Do not forward
                // them or replay an action whose outcome could be unknown.
                if !continueOnError {
                    throw AgentBrowserTransport.Failure("Batch stopped at step \(index + 1); \(results.count) earlier steps completed. Failed step outcome may be unknown; remaining steps not sent. Earlier artifacts are kept. Not retried.")
                }
                results.append(["index": index, "success": false, "error": "Step failed; page or partial artifact outcome may be unknown. Not retried."])
            }
        }
        return results
    }
}
