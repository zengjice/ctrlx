import Foundation
import Testing
@testable import CtrlxNetworking

struct BrowserExtensionStoreURLTests {
    @Test(arguments: [
        "https://chromewebstore.google.com/detail/fixture/abcdefghijklmnopabcdefghijklmnop",
        "https://chromewebstore.google.com/detail/abcdefghijklmnopabcdefghijklmnop?hl=en",
    ])
    func recognizesDetails(_ url: String) {
        #expect(BrowserExtensionStoreURL.extensionID(from: url) == "abcdefghijklmnopabcdefghijklmnop")
    }

    @Test(arguments: [
        "https://chromewebstore.google.com/", "https://chromewebstore.google.com/search/fixture",
        "https://chromewebstore.google.com/detail/invalid",
        "https://chromewebstore.google.com.evil.test/detail/abcdefghijklmnopabcdefghijklmnop",
        "https://chromewebstore.google.com@evil.test/detail/abcdefghijklmnopabcdefghijklmnop",
        "http://chromewebstore.google.com/detail/abcdefghijklmnopabcdefghijklmnop",
        "https://user@chromewebstore.google.com/detail/abcdefghijklmnopabcdefghijklmnop",
        "https://chromewebstore.google.com:443/detail/abcdefghijklmnopabcdefghijklmnop",
        "https://chromewebstore.google.com/detail/a/b/abcdefghijklmnopabcdefghijklmnop",
    ])
    func rejectsNonDetails(_ url: String) {
        #expect(BrowserExtensionStoreURL.extensionID(from: url) == nil)
    }

    @Test
    func oldHostsOmitStoreBrowsing() throws {
        let decoded = try JSONDecoder().decode(RemoteBrowserExtensionResult.self, from: Data("{}".utf8))
        #expect(decoded.canBrowseStore == nil)
        #expect(decoded.openedStoreTab == nil)
        let encoded = try JSONEncoder().encode(RemoteBrowserExtensionOperation.openStore)
        #expect(try JSONDecoder().decode(RemoteBrowserExtensionOperation.self, from: encoded) == .openStore)
    }
}
