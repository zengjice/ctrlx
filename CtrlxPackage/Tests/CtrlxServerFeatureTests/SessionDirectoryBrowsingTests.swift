#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    struct SessionDirectoryBrowsingTests {
        private func fixture() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-browse-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }

        @Test("Lists only immediate directories, supports literal names and directory symlinks")
        func directChildren() async throws {
            let files = FileManager.default
            let root = try fixture()
            defer { try? files.removeItem(at: root) }
            for name in ["Project 10", "Project 2", "新项目 ' $(x)", ".hidden", "outer/inner"] {
                try files.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            try Data("not a directory".utf8).write(to: root.appendingPathComponent("file"))
            try files.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: root.appendingPathComponent("outer"))
            let resolver = SessionDirectoryResolver()
            let result = try await resolver.list(.init(path: root.path + "/"))
            #expect(result.isExactDirectory)
            #expect(result.directory == root.path)
            #expect(!result.isTruncated)
            #expect(Set(result.entries.map(\.name)) == ["linked", "outer", "Project 2", "Project 10", "新项目 ' $(x)"])
            #expect(result.entries.map(\.name).filter { $0.hasPrefix("Project") } == ["Project 2", "Project 10"])
            for entry in result.entries {
                #expect(entry.path == root.appendingPathComponent(entry.name).path)
            }
            #expect(!result.entries.contains { $0.name == "inner" || $0.name == "file" })
            let hidden = try await resolver.list(.init(path: root.path, includeHidden: true))
            #expect(hidden.entries.contains { $0.name == ".hidden" })
            let explicitHidden = try await resolver.list(.init(path: root.path + "/.hi"))
            #expect(explicitHidden.entries.map(\.name) == [".hidden"])
            let alias = try await resolver.list(.init(path: root.path + "/linked/"))
            #expect(alias.entries.first?.path == root.path + "/linked/inner")
            #expect(alias.parentDirectory == root.path)
        }

        @Test("Partial paths complete case-insensitively, while exact paths browse children")
        func completion() async throws {
            let files = FileManager.default
            let root = try fixture()
            defer { try? files.removeItem(at: root) }
            try files.createDirectory(at: root.appendingPathComponent("Projects/child"), withIntermediateDirectories: true)
            let resolver = SessionDirectoryResolver()
            let partial = try await resolver.list(.init(path: root.path + "/pro"))
            #expect(!partial.isExactDirectory)
            #expect(partial.parentDirectory == root.path)
            #expect(partial.entries.map(\.name) == ["Projects"])
            let exact = try await resolver.list(.init(path: root.path + "/Projects"))
            #expect(exact.isExactDirectory)
            #expect(exact.parentDirectory == root.path)
            #expect(exact.entries.map(\.name) == ["child"])
            let empty = try await resolver.list(.init(path: root.path + "/no-match"))
            #expect(empty.entries.isEmpty)
            #expect(!empty.isExactDirectory)
        }

        @Test("Home expansion uses the Host, root has no parent, and response size is bounded")
        func homeAndLimits() async throws {
            let files = FileManager.default
            let root = try fixture()
            defer { try? files.removeItem(at: root) }
            for index in 0...SessionDirectoryResolver.maximumResults {
                try files.createDirectory(at: root.appendingPathComponent("repo-\(index)"), withIntermediateDirectories: true)
            }
            let resolver = SessionDirectoryResolver()
            let home = try await resolver.list(.init(path: "~/"))
            #expect(home.directory == files.homeDirectoryForCurrentUser.standardizedFileURL.path)
            #expect(try await resolver.list(.init(path: "/")).parentDirectory == nil)
            let limited = try await resolver.list(.init(path: root.path))
            #expect(limited.isTruncated)
            #expect(limited.entries.count == SessionDirectoryResolver.maximumResults)
            let filtered = try await resolver.list(.init(path: root.path + "/repo-20x"))
            #expect(filtered.entries.isEmpty)
            #expect(!filtered.isTruncated)
        }

        @Test("Invalid paths, missing parents, explicit missing directories and files fail")
        func invalidPaths() async throws {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("file")
            try Data().write(to: file)
            let resolver = SessionDirectoryResolver()
            for path in ["", "relative", "~other/repo", "/x\ny", "/" + String(repeating: "x", count: 4096), root.path + "/missing/child", root.path + "/missing/", file.path] {
                await #expect(throws: SessionDirectoryResolver.DirectoryError.self) {
                    try await resolver.list(.init(path: path))
                }
            }
        }

        @Test("Long directory paths cannot produce oversized encrypted responses")
        func byteLimit() async throws {
            let files = FileManager.default
            let root = try fixture()
            defer { try? files.removeItem(at: root) }
            var parent = root
            for _ in 0..<4 { parent.appendPathComponent(String(repeating: "p", count: 120)) }
            try files.createDirectory(at: parent, withIntermediateDirectories: true)
            for index in 0..<200 {
                try files.createDirectory(
                    at: parent.appendingPathComponent(String(repeating: "n", count: 180) + "-\(index)"),
                    withIntermediateDirectories: true
                )
            }
            let result = try await SessionDirectoryResolver().list(.init(path: parent.path))
            #expect(result.isTruncated)
            #expect(!result.entries.isEmpty)
            #expect(result.entries.count < 200)
            #expect(try JSONEncoder().encode(result.entries).count <= SessionDirectoryResolver.maximumEntryBytes + 2)
            #expect(try JSONEncoder().encode(result).count * 2 < RelayPayloadLimits.maxWebSocketFrameBytes)
        }

        @Test("Unreadable directories report an error instead of appearing empty")
        func permissionDenied() async throws {
            let root = try fixture()
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
                try? FileManager.default.removeItem(at: root)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
            await #expect(throws: SessionDirectoryResolver.DirectoryError.self) {
                try await SessionDirectoryResolver().list(.init(path: root.path))
            }
        }

        @Test("Read-only command handler preserves correlation and propagates listing errors")
        func handler() async {
            let spec = ListSessionDirectories(path: "~/Pro")
            let command = CommandMessage(paneId: "", command: spec.commandType)
            let listing = SessionDirectoryListing(directory: "/Host", parentDirectory: "/Host", isExactDirectory: false, entries: [])
            await withDependencies {
                $0[SessionDirectoryClient.self].list = { request in
                    #expect(request == spec)
                    return listing
                }
            } operation: {
                let response = await SessionDirectoryResolver.respond(to: command, request: spec)
                #expect(response.commandId == command.id)
                #expect(response.success)
                #expect(response.directoryListing == listing)
                #expect(response.paneId == nil)
            }
            await withDependencies {
                $0[SessionDirectoryClient.self].list = { _ in throw SessionDirectoryResolver.DirectoryError.inaccessible("/Host") }
            } operation: {
                let response = await SessionDirectoryResolver.respond(to: command, request: spec)
                #expect(!response.success)
                #expect(response.commandId == command.id)
                #expect(response.error?.contains("not accessible") == true)
            }
        }
    }
#endif
