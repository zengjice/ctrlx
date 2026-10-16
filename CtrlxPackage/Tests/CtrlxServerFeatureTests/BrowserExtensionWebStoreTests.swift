#if os(macOS)
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    struct BrowserExtensionWebStoreTests {
        let identifier = "imebogohheacbbmhfiiddakclhifpbde"

        @Test
        func parsesOnlyStoreIdentityAndBuildsEncodedDownload() throws {
            #expect(try BrowserExtensionWebStore.identifier(from: " \(identifier)\n") == identifier)
            #expect(try BrowserExtensionWebStore.identifier(from: "https://chromewebstore.google.com/detail/env-plugin/\(identifier)?hl=zh-CN") == identifier)
            let url = try BrowserExtensionWebStore.downloadURL(identifier: identifier, chromiumVersion: "152.0.7977.134")
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(url.host == "clients2.google.com")
            #expect(query.first { $0.name == "x" }?.value == "id=\(identifier)&uc")
            #expect(query.first { $0.name == "prodversion" }?.value == "152.0.7977.134")
            #expect(query.first { $0.name == "acceptformat" }?.value == "crx3")
        }

        @Test(arguments: [
            "https://chromewebstore.google.com.evil.test/detail/name/imebogohheacbbmhfiiddakclhifpbde",
            "https://evil.test/imebogohheacbbmhfiiddakclhifpbde",
            "http://chromewebstore.google.com/detail/name/imebogohheacbbmhfiiddakclhifpbde",
            "https://user@chromewebstore.google.com/detail/name/imebogohheacbbmhfiiddakclhifpbde",
            "https://chromewebstore.google.com:443/detail/name/imebogohheacbbmhfiiddakclhifpbde",
            "https://chromewebstore.google.com/collection/imebogohheacbbmhfiiddakclhifpbde",
            "imebogohheacbbmhfiiddakclhifpbdz", "imebogohheacbbmhfiiddakclhifpbde&uc",
        ])
        func rejectsNonStoreInput(_ input: String) {
            #expect(throws: (any Error).self) { try BrowserExtensionWebStore.identifier(from: input) }
        }

        @Test
        func restrictsRedirectsAndVersionInput() throws {
            for address in ["https://clients2.googleusercontent.com/crx", "https://clients2.google.com/service/update2/crx", "https://edgedl.me.gvt1.com/crx"] {
                #expect(try BrowserExtensionWebStore.allowedDownloadURL(#require(URL(string: address))))
            }
            for address in ["https://evilgoogleusercontent.com/crx", "https://googleusercontent.com.evil.test/crx", "http://clients2.googleusercontent.com/crx", "file:///tmp/package.crx", "https://user:password@clients2.google.com/crx"] {
                #expect(try !BrowserExtensionWebStore.allowedDownloadURL(#require(URL(string: address))))
            }
            #expect(throws: (any Error).self) { try BrowserExtensionWebStore.downloadURL(identifier: identifier, chromiumVersion: "152.0&x=other") }
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_EXTENSION_DOWNLOAD_TEST"] == "1"))
        func downloadsVerifiedENVPackageFromOfficialStore() async throws {
            let data = try await BrowserExtensionDownloadClient.liveValue.download(identifier, "152.0.7977.134")
            let verified = try BrowserExtensionCRX.verify(data)
            #expect(verified.extensionID == identifier)
            print("Official store ENV download verified: \(data.count) bytes, ID=\(verified.extensionID)")
        }
    }
#endif
