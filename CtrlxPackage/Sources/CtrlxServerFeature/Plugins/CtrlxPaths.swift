#if os(macOS)
    import Foundation

    /// The on-disk `~/.ctrlx/` layout for the in-process plugin runtime (spec §9).
    ///
    /// All paths derive from a single root so E2E runs can redirect the whole tree
    /// to a temp directory via an override (mirrors the `--ctrlx-state-root`
    /// launch flag). Directory creation is best-effort and trap-free: callers ask
    /// for a path and the matching parent directory is materialized on demand.
    ///
    /// ```text
    /// ~/.ctrlx/
    ///   registry.json                  ← canonical installed-plugin list
    ///   state/
    ///     ingress.sock                 ← THE app-owned ingress socket (one, not per-plugin)
    ///     plugins/<id>/
    ///       settings.json              ← user settings for this plugin
    ///       logs/sidecar.log           ← rotated 5 MB max (the core's log() sink)
    ///       cache/  db/                ← per-plugin scratch
    /// ```
    public struct CtrlxPaths: Sendable {
        /// The `~/.ctrlx` root. `registry.json` lives directly under it; the
        /// writable plugin state lives under `state/`.
        public let ctrlxRoot: URL

        /// `<ctrlxRoot>/state` (overridable for E2E isolation). When an explicit
        /// state-root override is supplied, `ctrlxRoot` becomes its parent so the
        /// whole tree (including `registry.json`) stays under the override.
        public let stateRoot: URL

        // MARK: - Initialization

        /// - Parameter stateRootOverride: When non-`nil`, used verbatim as
        ///   `stateRoot` (the E2E `--ctrlx-state-root` case). `ctrlxRoot`
        ///   becomes its parent directory so `registry.json` stays adjacent to the
        ///   redirected `state/`. When `nil`, the default `~/.ctrlx/state` layout
        ///   is used.
        public init(stateRootOverride: URL? = nil) {
            if let stateRootOverride {
                self.stateRoot = stateRootOverride.standardizedFileURL
                self.ctrlxRoot = stateRootOverride.deletingLastPathComponent().standardizedFileURL
            } else {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let root = home.appendingPathComponent(".ctrlx", isDirectory: true)
                self.ctrlxRoot = root.standardizedFileURL
                self.stateRoot = root.appendingPathComponent("state", isDirectory: true).standardizedFileURL
            }
        }

        // MARK: - Top-level paths

        /// `~/.ctrlx/registry.json` — canonical installed-plugin list (spec §9).
        public var registryPath: URL {
            ctrlxRoot.appendingPathComponent("registry.json")
        }

        /// `<stateRoot>/ingress.sock` — THE one app-owned ingress socket (spec §8).
        public var ingressSocketPath: URL {
            stateRoot.appendingPathComponent("ingress.sock")
        }

        /// `<stateRoot>/plugins` — parent of all per-plugin state directories.
        public var pluginsStateRoot: URL {
            stateRoot.appendingPathComponent("plugins", isDirectory: true)
        }

        /// `<ctrlxRoot>/plugins` — where folder-dropped sidecar bundles live
        /// (spec §9). Each immediate subdirectory is a self-contained plugin tree
        /// whose directory name must equal the plugin's sanitized id.
        public var pluginsDir: URL {
            ctrlxRoot.appendingPathComponent("plugins", isDirectory: true)
        }

        /// Ensure `<ctrlxRoot>/plugins/` exists. Best-effort; never traps.
        @discardableResult
        public func ensurePluginsDir() -> Bool {
            createDirectory(pluginsDir)
        }

        /// `<ctrlxRoot>/plugins/<id>` — the installed plugin bundle directory.
        public func pluginInstallDir(_ id: String) -> URL {
            pluginsDir.appendingPathComponent(Self.safeComponent(id), isDirectory: true)
        }

        /// `<ctrlxRoot>/plugins/<id>.installing` — staging directory used during
        /// URL-install before the atomic commit step.
        public func pluginStagingDir(_ id: String) -> URL {
            pluginsDir.appendingPathComponent(Self.safeComponent(id) + ".installing", isDirectory: true)
        }

        /// `<ctrlxRoot>/plugins/<id>.replacing` — temporary hold for the old
        /// install during an atomic overwrite. Matches the suffix used by
        /// `PluginInstaller.commitInstall`.
        public func pluginReplacingDir(_ id: String) -> URL {
            pluginsDir.appendingPathComponent(Self.safeComponent(id) + ".replacing", isDirectory: true)
        }

        // MARK: - Per-plugin paths

        /// `<stateRoot>/plugins/<id>/` — writable per-plugin scratch/state. The
        /// id is sanitized first (every per-plugin path funnels through here).
        public func pluginStateDir(_ id: String) -> URL {
            pluginsStateRoot.appendingPathComponent(Self.safeComponent(id), isDirectory: true)
        }

        /// Defense-in-depth: keep only `[a-z0-9-]` so a hostile `id` can't escape
        /// the plugins dir via `../` or an absolute path. Registered ids
        /// (`claude-code`, `codex`) already match, so this is a no-op for them.
        private static let allowedIDCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-"
        )
        private static func safeComponent(_ id: String) -> String {
            let safe = String(String.UnicodeScalarView(
                id.unicodeScalars.filter { allowedIDCharacters.contains($0) }
            ))
            return safe.isEmpty ? "_invalid_" : safe
        }

        /// `<stateRoot>/plugins/<id>/settings.json` — user settings for this plugin.
        public func pluginSettingsPath(_ id: String) -> URL {
            pluginStateDir(id).appendingPathComponent("settings.json")
        }

        /// `<stateRoot>/plugins/<id>/logs/` — log directory for this plugin.
        public func pluginLogDir(_ id: String) -> URL {
            pluginStateDir(id).appendingPathComponent("logs", isDirectory: true)
        }

        /// `<stateRoot>/plugins/<id>/logs/sidecar.log` — the core's `log()` sink (spec §15).
        public func pluginLogPath(_ id: String) -> URL {
            pluginLogDir(id).appendingPathComponent("sidecar.log")
        }

        // MARK: - Directory materialization (best-effort, trap-free)

        /// Ensure `ctrlxRoot` and `stateRoot` exist. Failures are swallowed —
        /// callers that need a path should not crash if the disk is unwritable; the
        /// subsequent file op surfaces the real error.
        @discardableResult
        public func ensureBaseDirectories() -> Bool {
            createDirectory(ctrlxRoot) && createDirectory(stateRoot)
        }

        /// Ensure `<stateRoot>/plugins/<id>/` (and `logs/`) exist, returning the
        /// state dir. Best-effort; never traps.
        @discardableResult
        public func ensurePluginStateDir(_ id: String) -> URL {
            let dir = pluginStateDir(id)
            createDirectory(dir)
            createDirectory(pluginLogDir(id))
            return dir
        }

        /// Best-effort directory creation; returns whether the directory exists
        /// afterwards. Never throws.
        @discardableResult
        private func createDirectory(_ url: URL) -> Bool {
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) { return true }
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                return true
            } catch {
                return fm.fileExists(atPath: url.path)
            }
        }
    }
#endif
