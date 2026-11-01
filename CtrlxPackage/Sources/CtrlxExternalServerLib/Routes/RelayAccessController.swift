import CtrlxNetworking
import Vapor

struct RelayAccessController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("access", "status") { req async throws -> Response in
            let status: RelayAccessStatus
            if let service = req.application.relayAccess {
                do {
                    let quota: RelayQuotaStatus
                    do {
                        quota = try await service.status(
                            token: req.headers.bearerAuthorization?.token ?? "",
                            requireAccount: req.query[String.self, at: "role"] == "account"
                        )
                    } catch {
                        try await req.application.relayAccessLimits.checkAnonymous(req, operation: "status", limit: 240)
                        throw error
                    }
                    try await req.application.relayAccessLimits.check("status:account:" + quota.accountID, limit: 240)
                    status = RelayAccessStatus(metered: true, quota: quota)
                } catch {
                    status = RelayAccessStatus(metered: true, failure: relayAccessFailure(error))
                }
            } else {
                status = RelayAccessStatus(metered: false)
            }
            let response = try await status.encodeResponse(for: req)
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return response
        }
    }
}

func relayAccessFailure(_ error: any Error) -> RelayAccessFailure {
    error as? RelayAccessFailure ?? RelayAccessFailure(code: .unavailable, message: "Relay quota storage is unavailable. Please try again later.")
}

struct RelayAccessStorageKey: StorageKey { typealias Value = RelayAccessService }

extension Application {
    var relayAccess: RelayAccessService? {
        storage[RelayAccessStorageKey.self]
    }
}

extension RelayAccessStatus: Content { }
