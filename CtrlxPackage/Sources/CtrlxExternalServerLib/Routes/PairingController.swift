import CtrlxNetworking
import Vapor

/// Handles HTTP endpoints for device pairing
struct PairingController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let pairing = routes.grouped("pairing")

        pairing.post("register", use: registerPairingCode)
        pairing.post("complete", use: completePairing)
        pairing.get(":pairId", "status", use: getPairingStatus)
        pairing.delete(":pairId", use: deletePairing)
    }

    /// Host registers a pairing code
    /// POST /api/pairing/register
    @Sendable
    func registerPairingCode(req: Request) async throws -> PairingResponse {
        // Operator maintenance switch (PAIRING_PAUSED_MESSAGE): refuse new
        // pairing registrations with the operator's message. Delivered as a
        // normal `.error` response body — both clients render an unrecognized
        // code's message verbatim, so this needs no client-side support.
        if let pausedMessage = req.application.pairingPausedMessage {
            await req.application.metricsService.incrementPausedPairingAttempts()
            return .error(ErrorInfo(
                message: pausedMessage,
                code: ErrorMessage.pairingPausedCode
            ))
        }

        let registration = try req.content.decode(PairingRegistration.self)

        if let access = req.application.relayAccess {
            do {
                _ = try await req.application.relayAccessLimits.authenticate(req, using: access, operation: "register", limit: 30, role: "account")
                return try .registered(await access.register(registration, token: req.headers.bearerAuthorization?.token))
            } catch {
                let failure = relayAccessFailure(error)
                return .error(ErrorInfo(message: failure.message, code: failure.code.rawValue))
            }
        }

        // Hosted-relay gate: hosts need a trial or active license. A fresh host
        // has no trial yet, so it reads as `.preTrial` (allowed) — the trial
        // clock itself doesn't start until a viewer completes pairing.
        let entitlement = await req.application.licensingService
            .checkEntitlement(hostDeviceId: registration.deviceId)
        guard entitlement.isAllowed else {
            await req.application.metricsService.incrementBlockedHostAttempts()
            return .error(ErrorInfo(
                message: "An active subscription is required to use the hosted relay",
                code: ErrorMessage.subscriptionRequiredCode
            ))
        }

        return await req.application.pairingService.registerCode(
            code: registration.pairingCode,
            deviceId: registration.deviceId,
            deviceName: registration.deviceName,
            username: registration.username,
            publicKey: registration.publicKey,
            publicKeyId: registration.publicKeyId
        )
    }

    /// Viewer completes pairing with a code
    /// POST /api/pairing/complete
    @Sendable
    func completePairing(req: Request) async throws -> PairingResponse {
        let completion = try req.content.decode(PairingCompletion.self)

        if let access = req.application.relayAccess {
            do {
                try await req.application.relayAccessLimits.checkAnonymous(req, operation: "pair", limit: 12)
                let (pair, info) = try await access.complete(completion)
                await req.application.pairingService.installPair(pair)
                return .paired(info)
            } catch {
                let failure = relayAccessFailure(error)
                return .error(ErrorInfo(message: failure.message, code: failure.code.rawValue))
            }
        }

        let response = await req.application.pairingService.completePairing(
            code: completion.pairingCode,
            deviceId: completion.deviceId,
            deviceName: completion.deviceName,
            publicKey: completion.publicKey,
            publicKeyId: completion.publicKeyId
        )

        // Start the host's free-trial clock the moment a viewer actually pairs —
        // not at register/first-touch. Idempotent; a no-op when licensing is off.
        if
            case let .paired(info) = response,
            let hostDeviceId = await req.application.pairingService.getPair(pairId: info.pairId)?.hostDeviceId {
            await req.application.licensingService.startTrialIfNeeded(hostDeviceId: hostDeviceId)
        }

        return response
    }

    /// Get pairing status
    /// GET /api/pairing/:pairId/status
    @Sendable
    func getPairingStatus(req: Request) async throws -> PairingStatus {
        guard let pairId = req.parameters.get("pairId") else {
            throw Abort(.badRequest, reason: "Missing pairId parameter")
        }

        if let access = req.application.relayAccess {
            do {
                _ = try await req.application.relayAccessLimits.authenticate(req, using: access, operation: "pair-access", limit: 120, pairID: pairId)
            } catch { throw Abort(.unauthorized, reason: relayAccessFailure(error).message) }
        }

        let connectionHub = req.application.connectionHub
        let pairingService = req.application.pairingService

        let legacyValid = await pairingService.isValidPair(pairId: pairId)
        let isValid = req.application.relayAccess != nil || legacyValid
        let completed = await pairingService.getPair(pairId: pairId) != nil
        let hostConnected = await connectionHub.isHostConnected(pairId: pairId)
        let viewerConnected = await connectionHub.isViewerConnected(pairId: pairId)
        let viewerDeviceName = await pairingService.getViewerDeviceName(pairId: pairId)

        return PairingStatus(
            valid: isValid,
            hostConnected: hostConnected,
            viewerConnected: viewerConnected,
            viewerDeviceName: viewerDeviceName,
            pairingCompleted: completed
        )
    }

    /// Delete a pairing
    /// DELETE /api/pairing/:pairId
    @Sendable
    func deletePairing(req: Request) async throws -> HTTPStatus {
        guard let pairId = req.parameters.get("pairId") else {
            throw Abort(.badRequest, reason: "Missing pairId parameter")
        }

        if let access = req.application.relayAccess {
            do {
                _ = try await access.authenticate(req.headers.bearerAuthorization?.token, pairID: pairId)
                try await access.removePair(pairId)
            } catch { throw Abort(.unauthorized, reason: relayAccessFailure(error).message) }
        }

        // Notify both sides that the pairing has been removed before disconnecting
        await req.application.connectionHub.broadcast(.unpaired, to: pairId)

        await req.application.pairingService.removePair(pairId: pairId)
        await req.application.connectionHub.disconnectAll(pairId: pairId)

        return .noContent
    }
}
