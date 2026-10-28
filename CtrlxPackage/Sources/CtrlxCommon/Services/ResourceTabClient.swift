import CtrlxNetworking
import Foundation

@MainActor
public enum ResourceTabClient {
    public static func request(_ request: ResourceTabRequest, client: ViewerRelayClient) async throws -> ResourceTabResponse {
        guard client.isHostConnected, client.hostSupportsIndependentResources else {
            throw FileBrowserError.message("Connect and update the Host Mac to use independent resource tabs.")
        }
        switch request.operation {
        case .authorize,
             .revoke,
             .returnControl:
            guard client.hostSupportsResourceAuthorization else { throw FileBrowserError.message("Update the Host browser runtime to use Agent authorization.") }
        default: break
        }
        let response = try await client.sendCommand(request, paneId: "", timeout: 240).get()
        guard response.success, let result = response.resourceTab else {
            throw FileBrowserError.message(response.error ?? "The Host did not confirm the resource operation.")
        }
        if let file = result.file {
            client.rememberOpenedFileTab(file)
        }
        if let browser = result.browser {
            client.rememberOpenedBrowser(browser)
        }
        if let simulator = result.simulator {
            client.rememberOpenedSimulator(simulator)
        }
        return result
    }
}
