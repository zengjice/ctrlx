import CtrlxNetworking
import Foundation

public extension AgentBrowserService {
    func browserTab(_ identifier: String, prepareDownload downloadID: String, filename: String, controlToken: String?, completion: @escaping (String?) -> Void) {
        guard
            let tab = tabs[identifier], !tab.isClosed, tab.manualTarget?.hostID == nil,
            let id = UUID(uuidString: downloadID) else { completion(nil)
            return
        }
        expireBrowserControls()
        let extensionLease = extensionControl.flatMap {
            $0.anchorID == tab.id || $0.pageID == tab.id ? $0.lease : nil
        }
        let lease = remoteControls[tab.id] ?? extensionLease
        if let controlToken {
            guard let lease, lease.id.uuidString == controlToken, lease.expires > .now else { completion(nil)
                return
            }
        } else if lease != nil {
            completion(nil)
            return
        }
        guard tab.downloads.filter(\.isActive).count < 4 else {
            tab.externalApplicationNotice = .init(message: "Wait for a download to finish before starting another.", isError: true)
            publishBrowserTabs()
            completion(nil)
            return
        }
        while tab.downloads.count >= 20, let index = tab.downloads.firstIndex(where: { !$0.isActive }) {
            tab.downloads.remove(at: index)
        }
        tab.downloads.append(.init(id: id, filename: HostBrowserDownloadStore.filename(filename)))
        publishBrowserTabs()
        Task {
            do {
                let path = try await downloadStore.prepare(id)
                guard !tab.isClosed, tab.downloads.contains(where: { $0.id == id && $0.state == .downloading }) else {
                    try await downloadStore.discard(id)
                    completion(nil)
                    return
                }
                completion(path)
            } catch {
                if let index = tab.downloads.firstIndex(where: { $0.id == id }) {
                    tab.downloads[index].state = .failed
                    tab.downloads[index].error = error.localizedDescription
                }
                publishBrowserTabs()
                completion(nil)
            }
        }
    }

    func browserTab(_ identifier: String, downloadChanged downloadID: String, state: String, received: Int64, total: Int64) {
        guard
            let tab = tabs[identifier], let id = UUID(uuidString: downloadID),
            let index = tab.downloads.firstIndex(where: { $0.id == id && $0.state == .downloading }) else { return }
        tab.downloads[index].receivedBytes = max(0, received)
        tab.downloads[index].totalBytes = max(0, total)
        guard state != "downloading" else { publishBrowserTabs()
            return
        }
        tab.downloads[index].state = state == "completed" ? .saving : state == "cancelled" ? .cancelled : .failed
        let name = tab.downloads[index].filename
        publishBrowserTabs()
        Task {
            do {
                if state == "completed" {
                    let path = try await downloadStore.complete(id, filename: name)
                    if let index = tab.downloads.firstIndex(where: { $0.id == id }) {
                        tab.downloads[index].filename = (path as NSString).lastPathComponent
                        tab.downloads[index].path = path
                        tab.downloads[index].state = .completed
                    }
                } else {
                    try await downloadStore.discard(id)
                    if state != "cancelled", let index = tab.downloads.firstIndex(where: { $0.id == id }) {
                        tab.downloads[index].error = "The download was interrupted. Try downloading the file again."
                    }
                }
            } catch {
                var message = error.localizedDescription
                do { try await downloadStore.discard(id) }
                catch { message += " Cleanup failed: \(error.localizedDescription)" }
                if let index = tab.downloads.firstIndex(where: { $0.id == id }) {
                    tab.downloads[index].state = .failed
                    tab.downloads[index].error = message
                }
            }
            publishBrowserTabs()
        }
    }
}
