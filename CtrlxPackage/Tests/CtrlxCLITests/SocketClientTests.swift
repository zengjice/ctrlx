import Darwin
import Foundation
import Testing
@testable import CtrlxCLI

struct SocketClientTests {
    @Test
    func shortWritesContinueOnlyUnsentBytes() throws {
        let bytes = Data(String(repeating: "分块数据\n", count: 10_000).utf8)
        var output = Data()
        var interrupted = false
        try SocketClient.writeAll(bytes) { remaining in
            if !interrupted {
                interrupted = true
                errno = EINTR
                return -1
            }
            let count = min(remaining.count, 173)
            output.append(contentsOf: remaining.prefix(count))
            return count
        }
        #expect(output == bytes)
        for count in [0, -1] {
            #expect(throws: CLIError.self) {
                try SocketClient.writeAll(bytes) { _ in
                    errno = EPIPE
                    return count
                }
            }
        }
    }
}
