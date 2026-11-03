#if os(macOS)
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Human browser downloads")
    struct HostBrowserDownloadTests {
        @Test
        func storesCompleteFilesWithoutOverwritingAndQuarantines() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = HostBrowserDownloadStore(directory: root)
            let first = UUID(), second = UUID()
            let path = try await store.prepare(first)
            let other = try await store.prepare(second)
            try Data("first".utf8).write(to: URL(fileURLWithPath: path))
            try Data("second".utf8).write(to: URL(fileURLWithPath: other))
            try Data("existing".utf8).write(to: root.appendingPathComponent("proof.txt"))
            let saved = try await store.complete(first, filename: "../../proof.txt")
            let next = try await store.complete(second, filename: "proof.txt")
            #expect((saved as NSString).lastPathComponent == "proof-2.txt")
            #expect((next as NSString).lastPathComponent == "proof-3.txt")
            #expect(try String(contentsOf: root.appendingPathComponent("proof.txt"), encoding: .utf8) == "existing")
            #expect(try String(contentsOfFile: saved, encoding: .utf8) == "first")
            #expect(try URL(fileURLWithPath: saved).resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 3)
        }

        @Test
        func cancelledAndMissingTransfersLeaveNoPartialFiles() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = HostBrowserDownloadStore(directory: root)
            let id = UUID()
            let path = try await store.prepare(id)
            try Data("partial".utf8).write(to: URL(fileURLWithPath: path))
            try await store.discard(id)
            try await store.discard(id)
            await #expect(throws: CocoaError.self) { try await store.complete(id, filename: "file") }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }

        @Test(arguments: ["", ".", "..", "\u{0}"])
        func emptyNamesUseSafeFallback(_ name: String) {
            #expect(HostBrowserDownloadStore.filename(name) == "Download")
        }

        @Test(arguments: ["pdf", "mp4"])
        func longFilenamesPreserveExtensionsAndAvoidOverwrites(_ suffix: String) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = HostBrowserDownloadStore(directory: root)
            let suggested = String(repeating: "a", count: 200) + ".\(suffix)"
            let name = HostBrowserDownloadStore.filename(suggested)
            #expect(name.count == 180)
            #expect((name as NSString).pathExtension == suffix)
            #expect(HostBrowserDownloadStore.filename(name) == name)

            var saved: [String] = []
            for contents in ["first", "second", "third"] {
                let id = UUID()
                let partial = try await store.prepare(id)
                try Data(contents.utf8).write(to: URL(fileURLWithPath: partial))
                try saved.append(await store.complete(id, filename: name))
            }
            let base = (name as NSString).deletingPathExtension
            #expect(saved.map { ($0 as NSString).lastPathComponent } == [name, "\(base)-2.\(suffix)", "\(base)-3.\(suffix)"])
            #expect(try saved.map { try String(contentsOfFile: $0, encoding: .utf8) } == ["first", "second", "third"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 3)
        }

        @Test
        func preservesShortNamesAndBoundsExtensionlessNames() {
            for name in ["report.pdf", "archive.tar.gz", ".hidden", "trailing."] {
                #expect(HostBrowserDownloadStore.filename(name) == name)
            }
            #expect(HostBrowserDownloadStore.filename(String(repeating: "a", count: 200)) == String(repeating: "a", count: 180))
            let oversizedSuffix = "a." + String(repeating: "b", count: 200)
            #expect(HostBrowserDownloadStore.filename(oversizedSuffix).count == 180)
        }

        @Test @MainActor
        func publishesProgressAndCompletedHostPath() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try await withDependencies {
                $0[BrowserDownloadsLocation.self] = .fixed(path: root.path)
            } operation: {
                let (service, _, descriptor) = try await RemoteBrowserControlTests().fixture()
                let tab = try #require(service.tabs[descriptor.id.uuidString])
                let id = UUID()
                let path: String? = await withCheckedContinuation { continuation in
                    service.browserTab(tab.identifier, prepareDownload: id.uuidString, filename: "proof.txt", controlToken: nil) {
                        continuation.resume(returning: $0)
                    }
                }
                try Data("proof".utf8).write(to: URL(fileURLWithPath: #require(path)))
                service.browserTab(tab.identifier, downloadChanged: id.uuidString, state: "downloading", received: 2, total: 5)
                #expect(service.descriptor(tab).downloads?.first?.receivedBytes == 2)
                #expect(service.descriptor(tab).downloads?.first?.path == nil)
                service.browserTab(tab.identifier, downloadChanged: id.uuidString, state: "completed", received: 5, total: 5)
                for _ in 0..<100 where tab.downloads.first?.isActive == true {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(service.descriptor(tab).downloads?.first?.state == .completed)
                #expect(service.descriptor(tab).downloads?.first?.path == root.appendingPathComponent("proof.txt").path)
                await service.shutdown()
            }
        }

        @Test @MainActor
        func viewerDownloadUsesHostDirectoryAndFailureCleansPartial() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try await withDependencies {
                $0[BrowserDownloadsLocation.self] = .fixed(path: root.path)
            } operation: {
                let (service, _, descriptor) = try await RemoteBrowserControlTests().fixture()
                let tab = try #require(service.tabs[descriptor.id.uuidString])
                let request = BrowseBrowser(sessionName: "test", tabID: tab.id, surfaceID: UUID(), operation: .takeControl)
                let lease = try #require(try await service.handleBrowser(request, viewerID: "viewer").controlID)
                let id = UUID()
                let path: String? = await withCheckedContinuation { continuation in
                    service.browserTab(tab.identifier, prepareDownload: id.uuidString, filename: "viewer.txt", controlToken: lease.uuidString) {
                        continuation.resume(returning: $0)
                    }
                }
                let partial = try URL(fileURLWithPath: #require(path))
                #expect(partial.path.hasPrefix(root.path + "/"))
                try Data("partial".utf8).write(to: partial)
                service.browserTab(tab.identifier, downloadChanged: id.uuidString, state: "failed", received: 7, total: 20)
                for _ in 0..<100 where FileManager.default.fileExists(atPath: partial.path) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(!FileManager.default.fileExists(atPath: partial.path))
                #expect(service.descriptor(tab).downloads?.first?.state == .failed)
                #expect(service.descriptor(tab).downloads?.first?.path == nil)
                await service.shutdown()
            }
        }

        @Test @MainActor
        func rejectsStaleViewerAndCleansUpCloseDuringPreparation() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try await withDependencies {
                $0[BrowserDownloadsLocation.self] = .fixed(path: root.path)
            } operation: {
                let (service, _, descriptor) = try await RemoteBrowserControlTests().fixture()
                let tab = try #require(service.tabs[descriptor.id.uuidString])
                var rejected = false
                service.browserTab(tab.identifier, prepareDownload: UUID().uuidString, filename: "stale", controlToken: "expired") {
                    #expect($0 == nil)
                    rejected = true
                }
                #expect(rejected)
                #expect(tab.downloads.isEmpty)
                let path: String? = await withCheckedContinuation { continuation in
                    service.browserTab(tab.identifier, prepareDownload: UUID().uuidString, filename: "closed", controlToken: nil) {
                        continuation.resume(returning: $0)
                    }
                    service.browserTabClosed(tab.identifier)
                }
                #expect(path == nil)
                #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
                await service.shutdown()
            }
        }
    }
#endif
