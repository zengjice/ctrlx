#if os(macOS)
    import Darwin
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("API socket response")
    struct APISocketResponseTests {
        @Test
        func disconnectedClientReturnsBrokenPipeWithoutTerminatingTheHost() async throws {
            var sockets: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
            defer { close(sockets[0]) }
            for fd in sockets {
                try #require(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0)
            }
            try LiveAPISocketServer.configureConnection(sockets[0])
            close(sockets[1])

            // A concurrent Process launch may briefly inherit the peer until
            // exec. Observe EOF before asserting that the client disconnected.
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var byte: UInt8 = 0
            var count = recv(sockets[0], &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            while count < 0, errno == EAGAIN || errno == EINTR, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
                count = recv(sockets[0], &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            }
            try #require(count == 0)

            #expect(throws: POSIXError(.EPIPE)) {
                try LiveAPISocketServer.writeResponse(Data("response\n".utf8), to: sockets[0])
            }
            var enabled: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: enabled))
            #expect(getsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, &size) == 0)
            #expect(enabled == 1)
        }

        @Test
        func largeResponseArrivesCompletelyAcrossASmallSocketBuffer() throws {
            var sockets: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
            let sender = sockets[0], receiver = sockets[1]
            defer { close(sender)
                close(receiver)
            }
            try LiveAPISocketServer.configureConnection(sender)
            var bufferSize: Int32 = 4_096
            try #require(setsockopt(sender, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout.size(ofValue: bufferSize))) == 0)
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            try #require(setsockopt(sender, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0)
            let expected = Data(repeating: 0x61, count: 2 * 1_024 * 1_024) + Data("\n".utf8)
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-api-response-\(UUID().uuidString)")
            try Data().write(to: output)
            defer { try? FileManager.default.removeItem(at: output) }
            let file = try FileHandle(forWritingTo: output)
            defer { try? file.close() }
            // An independent reader avoids blocking two cooperative executor threads on socket I/O.
            let reader = Process()
            reader.executableURL = URL(fileURLWithPath: "/bin/cat")
            reader.standardInput = FileHandle(fileDescriptor: receiver, closeOnDealloc: false)
            reader.standardOutput = file
            try reader.run()
            defer {
                if reader.isRunning {
                    reader.terminate()
                }
                reader.waitUntilExit()
            }
            try LiveAPISocketServer.writeResponse(expected, to: sender)
            shutdown(sender, SHUT_WR)
            reader.waitUntilExit()
            #expect(reader.terminationStatus == 0)
            #expect(try Data(contentsOf: output) == expected)
        }
    }
#endif
