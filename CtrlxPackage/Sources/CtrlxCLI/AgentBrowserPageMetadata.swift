import CryptoKit
import Darwin
import Foundation

enum AgentBrowserPageMetadata {
    /// A daemon restart can reuse upstream init-script-1. Public UUID handles
    /// must never delete a different script after that restart.
    static func generation(socket: URL) throws -> String {
        var info = stat()
        guard lstat(socket.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else {
            throw AgentBrowserTransport.Failure("Engine script handles expired; inspect init list before adding new scripts.")
        }
        return "\(info.st_dev):\(info.st_ino):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    static func initCommand(_ words: [String], root: URL) throws -> [String: Any] {
        let socket = root.appendingPathComponent("page.sock")
        let stamp = try generation(socket: socket)
        let file = root.appendingPathComponent("init-handles.json")
        let saved = FileManager.default.fileExists(atPath: file.path) ? try AgentBrowserTransport.readPrivateJSON(file) : [:]
        var handles = saved["generation"] as? String == stamp ? saved["handles"] as? [String: String] ?? [:] : [:]
        if words[1] == "list" {
            return ["scripts": handles.keys.sorted(), "lifetime": "current tab engine; navigation preserves IDs, setup/idle/restart invalidates them"]
        }
        let publicID: String
        let result: [String: Any]
        if words[1] == "add" {
            guard handles.count < 16 else { throw AgentBrowserTransport.Failure("At most 16 dynamic init scripts per tab engine.") }
            guard let reply = try AgentBrowserTransport.request([
                "id": UUID().uuidString, "action": "addinitscript", "script": words[2],
            ], socketPath: socket.path, upstream: true) as? [String: Any],
                  let identifier = reply["identifier"] as? String else {
                throw AgentBrowserTransport.Failure("Init script result invalid; effect may be unknown. Not retried.")
            }
            publicID = UUID().uuidString
            handles[publicID] = identifier
            result = ["added": true, "identifier": publicID, "reloadRequired": true]
        } else {
            publicID = words[2]
            guard let identifier = handles[publicID] else { throw AgentBrowserTransport.Failure("Unknown or expired init script ID; no script removed.") }
            _ = try AgentBrowserTransport.request([
                "id": UUID().uuidString, "action": "removeinitscript", "identifier": identifier,
            ], socketPath: socket.path, upstream: true)
            handles.removeValue(forKey: publicID)
            result = ["removed": true, "identifier": publicID, "reloadRequired": true]
        }
        try AgentBrowserTransport.writePrivateJSON(["generation": stamp, "handles": handles], to: file)
        return result
    }

    /// Compact, untrusted discovery only; full schemas still require explicit list.
    static func catalog(_ tools: [[String: Any]]) throws -> (digest: String, summary: [String: Any]) {
        let ordered = tools.sorted {
            (($0["name"] as? String ?? "") + ($0["frameId"] as? String ?? "")) <
            (($1["name"] as? String ?? "") + ($1["frameId"] as? String ?? ""))
        }
        let bytes = try JSONSerialization.data(withJSONObject: ordered, options: [.sortedKeys])
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var entries: [[String: String]] = [], size = 256, truncated = false
        for tool in ordered {
            let description = tool["description"] as? String ?? ""
            let entry = ["name": tool["name"] as? String ?? "", "origin": tool["origin"] as? String ?? "",
                         "frameId": tool["frameId"] as? String ?? "", "description": String(description.prefix(160))]
            let count = try JSONSerialization.data(withJSONObject: entry).count
            guard entries.count < 16, size + count < 4096 else { truncated = true; continue }
            truncated = truncated || description.count > 160
            size += count; entries.append(entry)
        }
        return (digest, ["status": "ready", "experimental": true, "untrusted": true,
                         "available": !tools.isEmpty, "toolCount": tools.count, "tools": entries, "truncated": truncated])
    }

    static func discover(after result: Any, root: URL) -> Any {
        guard var body = result as? [String: Any] else { return result }
        do {
            guard let data = try AgentBrowserTransport.request([
                "id": UUID().uuidString, "action": "webmcp_list",
            ], socketPath: root.appendingPathComponent("page.sock").path, upstream: true, timeoutSeconds: 2) as? [String: Any],
                  let tools = data["tools"] as? [[String: Any]] else {
                throw AgentBrowserTransport.Failure("Invalid discovery response.")
            }
            let (digest, summary) = try catalog(tools)
            let file = root.appendingPathComponent("webmcp-catalog.json")
            let saved = FileManager.default.fileExists(atPath: file.path) ? try AgentBrowserTransport.readPrivateJSON(file) : [:]
            if saved["digest"] as? String != digest {
                try AgentBrowserTransport.writePrivateJSON(["digest": digest], to: file)
                // No noise on an ordinary site's initially empty catalog; do
                // explicitly clear a previously advertised nonempty catalog.
                if !tools.isEmpty || saved["digest"] != nil { body["webmcp"] = summary }
            }
        } catch {
            // A metadata failure must not turn a completed mutation into an
            // apparent action failure or prompt automatic replay.
            body["webmcp"] = ["status": "unavailable", "untrusted": true, "hint": "Explicit webmcp list can inspect availability; page action was not retried."]
        }
        return body
    }
}
