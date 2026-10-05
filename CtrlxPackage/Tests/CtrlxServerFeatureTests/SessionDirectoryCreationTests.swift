#if os(macOS)
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    struct SessionDirectoryCreationTests {
        private func fixture() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-create-directory-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            return root
        }

        @Test("Creates one literal child and returns its Host path, including symlink parents")
        func create() async throws {
            let root = try fixture()
            let files = FileManager.default
            defer { try? files.removeItem(at: root) }
            let resolver = SessionDirectoryResolver()
            let name = "新项目 ' $(x)"
            let path = try await resolver.create(.init(parentDirectory: root.path, name: name))
            #expect(path == root.appendingPathComponent(name).path)
            #expect(try await resolver.list(.init(path: path)).isExactDirectory)
            let alias = root.appendingPathComponent("alias")
            try files.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent(name))
            let nested = try await resolver.create(.init(parentDirectory: alias.path, name: "child"))
            #expect(nested == alias.path + "/child")
            #expect(files.fileExists(atPath: root.appendingPathComponent(name + "/child").path))
        }

        @Test("Existing directory, file and symlink are never overwritten")
        func duplicates() async throws {
            let root = try fixture()
            let files = FileManager.default
            defer { try? files.removeItem(at: root) }
            try files.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: root.appendingPathComponent("file"))
            try files.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("missing"))
            let resolver = SessionDirectoryResolver()
            for name in ["folder", "file", "link"] {
                await #expect(throws: SessionDirectoryResolver.DirectoryError.alreadyExists(name)) {
                    try await resolver.create(.init(parentDirectory: root.path, name: name))
                }
            }
            #expect(try String(contentsOf: root.appendingPathComponent("file"), encoding: .utf8) == "keep")
            #expect(try files.destinationOfSymbolicLink(atPath: root.path + "/link") == root.path + "/missing")
        }

        @Test("Invalid names and missing parents cannot create intermediate directories")
        func invalid() async throws {
            let root = try fixture()
            let files = FileManager.default
            defer { try? files.removeItem(at: root) }
            let resolver = SessionDirectoryResolver()
            for name in ["", ".", "..", "nested/child", "bad\nname"] {
                await #expect(throws: SessionDirectoryResolver.DirectoryError.self) {
                    try await resolver.create(.init(parentDirectory: root.path, name: name))
                }
            }
            try Data().write(to: root.appendingPathComponent("file"))
            for parent in ["relative", root.path + "/missing", root.path + "/file", "/" + String(repeating: "x", count: 4096)] {
                await #expect(throws: SessionDirectoryResolver.DirectoryError.self) {
                    try await resolver.create(.init(parentDirectory: parent, name: "child"))
                }
            }
            #expect(try files.contentsOfDirectory(atPath: root.path) == ["file"])
        }

        @Test("Unwritable parents report failure instead of a successful creation")
        func permissionDenied() async throws {
            let root = try fixture()
            let files = FileManager.default
            defer {
                try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
                try? files.removeItem(at: root)
            }
            try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
            await #expect(throws: NSError.self) {
                try await SessionDirectoryResolver().create(.init(parentDirectory: root.path, name: "child"))
            }
            #expect(!files.fileExists(atPath: root.path + "/child"))
        }

        @Test("Cancelled creation does not mutate the filesystem")
        func cancellation() async throws {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await SessionDirectoryResolver().create(.init(parentDirectory: root.path, name: "child"))
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(!FileManager.default.fileExists(atPath: root.path + "/child"))
        }

        @Test("Handler acknowledges success/error without creating tmux state")
        func handler() async {
            let spec = CreateSessionDirectory(parentDirectory: "/Host", name: "child")
            let command = CommandMessage(paneId: "", command: spec.commandType)
            await withDependencies {
                $0[SessionDirectoryClient.self].create = { request in
                    #expect(request == spec)
                    return "/Host/child"
                }
            } operation: {
                let response = await SessionDirectoryResolver.respond(to: command, request: spec)
                #expect(response.success)
                #expect(response.commandId == command.id)
                #expect(response.createdDirectory == "/Host/child")
                #expect(response.paneId == nil)
            }
            await withDependencies {
                $0[SessionDirectoryClient.self].create = { _ in throw SessionDirectoryResolver.DirectoryError.alreadyExists("child") }
            } operation: {
                let response = await SessionDirectoryResolver.respond(to: command, request: spec)
                #expect(!response.success)
                #expect(response.commandId == command.id)
                #expect(response.createdDirectory == nil)
                #expect(response.error?.contains("already exists") == true)
            }
        }
    }
#endif
