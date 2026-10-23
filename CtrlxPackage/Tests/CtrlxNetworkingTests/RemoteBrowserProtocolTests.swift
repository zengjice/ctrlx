import Foundation
import Testing
@testable import CtrlxNetworking

@Suite("Remote browser protocol")
struct RemoteBrowserProtocolTests {
    @Test
    func wireRoundTrip() throws {
        let operations: [RemoteBrowserOperation] = [
            .create,
            .openPane(url: nil),
            .openPane(url: "http://localhost:3000"),
            .frame,
            .takeControl,
            .releaseControl,
            .navigate("https://example.com/中文"),
            .back,
            .forward,
            .reload,
            .close,
            .networkPermission(id: UUID(), allow: true),
            .networkPermission(id: UUID(), allow: false),
            .fit(width: 390, height: 700),
            .text("中文\nsecond line"),
            .key(.init("Enter", keyCode: 13)),
            .pointer(.init(.down, x: 2, y: 5, button: .left)),
        ]
        for operation in operations {
            let request = BrowseBrowser(
                sessionName: "same",
                tabID: UUID(),
                surfaceID: UUID(),
                controlID: UUID(),
                generation: 42,
                operation: operation
            )
            let copy = try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(request.commandType))
            #expect(copy == request.commandType)
        }
    }

    @Test
    func oldHostDoesNotAdvertiseSupport() throws {
        let data = Data(#"{"pairId":"old","paneStates":{},"homeDirectory":""}"#.utf8)
        let state = try JSONDecoder().decode(SessionStateMessage.self, from: data)
        #expect(state.supportsBrowserSharing == nil)
        #expect(state.supportsPaneBrowser == nil)
        #expect(state.browserTabs == nil)
        let tab = RemoteBrowserTab(id: UUID(), sessionName: "s", title: "page", url: "about:blank", isLoading: false, isAgentOwned: true)
        let updated = SessionStateMessage(pairId: "a", paneStates: [:], supportsBrowserSharing: true, supportsPaneBrowser: true, browserTabs: [tab]).withPairId("b")
        #expect(updated.supportsBrowserSharing == true)
        #expect(updated.supportsPaneBrowser == true)
        #expect(updated.browserTabs == [tab])
        #expect(try JSONDecoder().decode(RemoteBrowserTab.self, from: JSONEncoder().encode(tab)).sourcePaneID == nil)
        #expect(try JSONDecoder().decode(RemoteBrowserTab.self, from: JSONEncoder().encode(tab)).networkPermission == nil)
    }

    @Test
    func networkPermissionIsAdditive() throws {
        let permission = BrowserNetworkPermission(id: UUID(), origin: "https://example.com", localNetwork: false, loopbackNetwork: true)
        let tab = RemoteBrowserTab(id: UUID(), sessionName: "s", title: "page", url: "https://example.com", isLoading: false, isAgentOwned: false, networkPermission: permission)
        #expect(try JSONDecoder().decode(RemoteBrowserTab.self, from: JSONEncoder().encode(tab)) == tab)
        struct LegacyTab: Decodable { let id: UUID
            let title: String
        }
        #expect(try JSONDecoder().decode(LegacyTab.self, from: JSONEncoder().encode(tab)).id == tab.id)
    }

    @Test
    func paneAssociationDoesNotRequireAgentIdentity() throws {
        let tab = RemoteBrowserTab(
            id: UUID(),
            sessionName: "s",
            windowID: "@2",
            title: "Page",
            url: "https://example.com",
            isLoading: false,
            isAgentOwned: false,
            sourcePaneID: "%7"
        )
        let copy = try JSONDecoder().decode(RemoteBrowserTab.self, from: JSONEncoder().encode(tab))
        #expect(copy == tab && copy.sourceAgent == nil && copy.sourcePaneID == "%7")
    }

    @Test
    func extensionWindowMetadataIsAdditive() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let tab = RemoteBrowserTab(
            id: UUID(),
            sessionName: "s",
            title: "Extension page",
            url: "https://example.com",
            isLoading: false,
            isAgentOwned: false,
            isExtensionWindow: true
        )
        #expect(try decoder.decode(RemoteBrowserTab.self, from: encoder.encode(tab)) == tab)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoder.encode(tab)) as? [String: Any])
        legacy.removeValue(forKey: "isExtensionWindow")
        let old = try decoder.decode(RemoteBrowserTab.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.isExtensionWindow == nil)
        #expect(old.id == tab.id)
    }

    @Test
    func extensionCommandsAndReceiptsRoundTrip() throws {
        let id = UUID()
        let operations: [RemoteBrowserExtensionOperation] = [
            .acquire, .release, .list, .openWindow, .showSurface(.manager), .showSurface(.page), .openOptions("extension-id"),
            .prepareStore(input: "store-id", replacingID: nil),
            .beginUpload(id: id, name: "package.zip", size: 3, replacingID: "installed-id"),
            .appendUpload(id: id, offset: 0, data: Data([1, 2, 3])),
            .finishUpload(id: id, sha256: "digest"), .cancelUpload(id), .install(id), .discard(id),
            .setEnabled(id: "extension", enabled: false), .remove("extension"), .frame,
            .text("中文"), .key(.init("Enter", keyCode: 13)), .pointer(.init(.down, x: 1, y: 2, button: .left)),
            .fit(width: 800, height: 600),
        ]
        for operation in operations {
            let request = BrowseBrowser(
                sessionName: "s",
                tabID: UUID(),
                surfaceID: UUID(),
                controlID: UUID(),
                generation: 3,
                operation: .extensions(operation)
            )
            let decoded = try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(request.commandType))
            #expect(decoded == request.commandType)
        }
        let preview = RemoteBrowserExtensionPreview(
            id: id,
            source: .crx,
            name: "Fixture",
            version: "2",
            extensionID: "extension-id",
            sha256: "digest",
            permissions: ["storage"],
            hostPermissions: ["https://example.com/*"],
            contentScriptMatches: [],
            optionalPermissions: [],
            optionalHostPermissions: [],
            previousVersion: "1",
            previousSource: .zip
        )
        let response = RemoteBrowserResponse(controlID: UUID(), extensions: .init(prepared: preview, surface: .manager))
        #expect(try JSONDecoder().decode(RemoteBrowserResponse.self, from: JSONEncoder().encode(response)) == response)
        let old = try JSONDecoder().decode(SessionStateMessage.self, from: Data(#"{"pairId":"old","paneStates":{},"homeDirectory":""}"#.utf8))
        #expect(old.supportsBrowserExtensions == nil)
        let new = SessionStateMessage(pairId: "a", paneStates: [:], supportsBrowserExtensions: true).withPairId("b")
        #expect(new.supportsBrowserExtensions == true)
        let legacy = Data(#"{"id":"fixture","name":"Fixture","version":"1","state":"ENABLED","canUpdate":true}"#.utf8)
        #expect(try JSONDecoder().decode(RemoteBrowserExtension.self, from: legacy).hasOptions == nil)
        let entry = RemoteBrowserExtension(id: "fixture", name: "Fixture", version: "1", state: "ENABLED", canUpdate: true, hasOptions: true)
        let options = RemoteBrowserExtensionResult(entries: [entry], surface: .options)
        #expect(try JSONDecoder().decode(RemoteBrowserExtensionResult.self, from: JSONEncoder().encode(options)) == options)
    }

    @Test
    func hostNavigationOnlyAcceptsBoundedWebURLs() throws {
        for address in ["https://example.com", "http://localhost:3000/中文", "http://127.0.0.1/"] {
            #expect(try BrowserWebURL.isSupported(#require(URL(string: address))))
        }
        for address in ["file:///tmp/a", "javascript:alert(1)", "ftp://example.com", "about:blank", "./page", "https://example.com/" + String(repeating: "x", count: 8_192)] {
            #expect(try !BrowserWebURL.isSupported(#require(URL(string: address))))
        }
    }

    @Test(arguments: [
        "https://user:pass@example.com/path",
        "https://user@example.com/path",
        "https://:pass@example.com/path",
        "https://@example.com/path",
        "https://user%40name:pass@example.com/path",
    ])
    func hostNavigationRejectsEmbeddedCredentials(_ address: String) throws {
        let url = try #require(URL(string: address))
        #expect(!BrowserWebURL.isSupported(url))
        #expect(BrowserWebURL.normalized(url) == nil)
    }

    @Test(arguments: [
        ("http://localhost:3000", "http://localhost:3000/"),
        ("HTTP://LOCALHOST:3000", "http://localhost:3000/"),
        ("https://EXAMPLE.com:443", "https://example.com/"),
        ("http://EXAMPLE.com:80?q=one#two", "http://example.com/?q=one#two"),
        ("https://EXAMPLE.com:444/a%2Fb?q=a%26b&q=c#part", "https://example.com:444/a%2Fb?q=a%26b&q=c#part"),
    ])
    func navigationNormalizesOriginSpelling(_ address: String, _ expected: String) throws {
        let url = try #require(URL(string: address))
        let normalized = try #require(BrowserWebURL.normalized(url))
        #expect(normalized.absoluteString == expected)
        #expect(BrowserWebURL.normalized(normalized) == normalized)
    }

    @Test(arguments: [
        "https://example.com/page/",
        "https://example.com/Page",
        "https://example.com/page?q=1",
        "https://example.com/page#part",
        "https://example.com:444/page",
        "http://example.com/page",
    ])
    func normalizationPreservesDistinctDestinations(_ address: String) throws {
        let originalURL = try #require(URL(string: "https://example.com/page"))
        let destinationURL = try #require(URL(string: address))
        let original = try #require(BrowserWebURL.normalized(originalURL))
        let destination = try #require(BrowserWebURL.normalized(destinationURL))
        #expect(original != destination)
    }

    @Test
    func adaptiveFrameSizeIsAdditiveForOldHostsAndViewers() throws {
        struct LegacyRequest: Codable {
            let sessionName: String
            let surfaceID: UUID
            let operation: RemoteBrowserOperation
        }
        let legacy = LegacyRequest(sessionName: "s", surfaceID: UUID(), operation: .frame)
        let decoded = try JSONDecoder().decode(BrowseBrowser.self, from: JSONEncoder().encode(legacy))
        #expect(decoded.frameMaxDimension == nil)
        let updated = BrowseBrowser(sessionName: "s", surfaceID: legacy.surfaceID, frameMaxDimension: 2_560, operation: .frame)
        let data = try JSONEncoder().encode(updated)
        #expect(try JSONDecoder().decode(BrowseBrowser.self, from: data) == updated)
        #expect(try JSONDecoder().decode(LegacyRequest.self, from: data).operation == .frame)
        let command = try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(updated.commandType))
        #expect(command == updated.commandType)
    }

    @Test
    func frameBudgetFitsEncryptedRelayEnvelope() throws {
        let frame = RemoteBrowserFrame(jpeg: Data(repeating: 1, count: RemoteBrowserFrame.maximumBytes), width: 1_200, height: 700, generation: 1)
        #expect(frame.isValid)
        let payload = CommandResponseMessage(commandId: UUID(), success: true, browser: .init(frame: frame))
        let encoded = try JSONEncoder().encode(payload)
        // Encryption adds a second base64 envelope, plus authentication/JSON overhead.
        #expect(encoded.count * 4 / 3 + 8_192 < RelayPayloadLimits.maxWebSocketFrameBytes)
        #expect(!RemoteBrowserFrame(jpeg: frame.jpeg + Data([0]), width: 1_200, height: 700, generation: 1).isValid)
        #expect(!RemoteBrowserFrame(jpeg: Data([0]), width: .nan, height: 700, generation: 1).isValid)
    }

    @Test
    func pointerValidation() {
        #expect(RemoteBrowserPointer(.move, x: 50, y: 40, buttons: 1).isValid)
        #expect(!RemoteBrowserPointer(.move, x: -.infinity, y: 40).isValid)
        #expect(!RemoteBrowserPointer(.move, x: 50, y: 40, deltaY: 10_000).isValid)
    }
}
