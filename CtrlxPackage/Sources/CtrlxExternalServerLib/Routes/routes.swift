import Vapor

/// Registers all application routes
func routes(_ app: Application) throws {
    // Health check endpoint
    app.get("health") { _ -> HealthResponse in
        HealthResponse(status: "ok")
    }
    app.get("ready") { _ -> HealthResponse in
        HealthResponse(status: "ok")
    }
    app.get("version") { request -> VersionResponse in
        VersionResponse(info: request.application.relayBuildInfo)
    }
    app.get("source") { request -> SourceResponse in
        SourceResponse(info: request.application.relayBuildInfo)
    }

    // Prometheus metrics endpoint at root (NOT under /api).
    // Authenticated via METRICS_TOKEN bearer header — see MetricsController.
    try app.register(collection: MetricsController())

    // API routes group
    let api = app.grouped("api")
    try api.register(collection: RelayAccessController())

    // Register controllers
    try api.register(collection: PairingController())
    try api.register(collection: LicenseController())
    try api.register(collection: WebSocketController())
}

// MARK: - Health Response

struct HealthResponse: Content {
    let status: String
}

struct VersionResponse: Content {
    let name: String
    let version: String
    let commit: String
    let protocolVersion: String
    let source: String
    let sourceIsExact: Bool
    let license: String

    init(info: RelayBuildInfo) {
        name = RelayBuildInfo.productName
        version = info.version
        commit = info.commit
        protocolVersion = info.protocolVersion
        source = info.sourceURL
        sourceIsExact = info.hasExactSource
        license = "AGPL-3.0-only"
    }
}

struct SourceResponse: Content {
    let source: String
    let commit: String
    let exact: Bool
    let license: String

    init(info: RelayBuildInfo) {
        source = info.sourceURL
        commit = info.commit
        exact = info.hasExactSource
        license = "AGPL-3.0-only"
    }
}
