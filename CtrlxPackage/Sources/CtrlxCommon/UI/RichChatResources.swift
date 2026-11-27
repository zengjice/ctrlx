#if os(macOS)
    import Foundation

    actor RichChatResources {
        static let shared = RichChatResources()

        struct Bootstrap: Sendable {
            let scripts: [String]
            let html: String
        }

        private var cachedBootstrap: Bootstrap?
        private var cachedMermaid: String?

        func bootstrap() throws -> Bootstrap {
            if let cachedBootstrap {
                return cachedBootstrap
            }
            let scripts = try [
                ("ArtifactPreview", "marked.umd.js"), ("ArtifactPreview", "purify.min.js"),
                ("ArtifactPreview", "svg.js"), ("OrbieChat", "vendor.js"), ("OrbieChat", "chat.js"),
            ].map { try resource($0.1, in: $0.0) }
            let css = try ["markdown.css", "highlight.css", "chat.css"].map { try resource($0, in: "OrbieChat") }.joined(separator: "\n")
                + "\n@media(prefers-color-scheme:dark){" + resource("highlight-dark.css", in: "OrbieChat") + "}"
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; frame-src about:; connect-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
            <style>\(css)</style></head><body><main id="messages" aria-label="Conversation"></main><button id="latest" hidden>Back to latest ↓</button></body></html>
            """
            let bootstrap = Bootstrap(scripts: scripts, html: html)
            cachedBootstrap = bootstrap
            return bootstrap
        }

        func mermaid() throws -> String {
            if let cachedMermaid {
                return cachedMermaid
            }
            let source = try resource("mermaid.min.js", in: "ArtifactPreview")
            cachedMermaid = source
            return source
        }

        private func resource(_ name: String, in directory: String) throws -> String {
            guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: directory) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
    }
#endif
