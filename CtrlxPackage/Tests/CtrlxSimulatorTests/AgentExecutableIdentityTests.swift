#if os(macOS)
    import Darwin
    import Testing
    @testable import CtrlxSimulatorProtocol

    struct AgentExecutableIdentityTests {
        @Test(arguments: ["codex", "codex-code-mode-host", "claude", "opencode", "omp", "pi"])
        func removedSupportedExecutable(_ name: String) {
            #expect(AgentExecutableIdentity.resolve(path: nil, errorCode: ENOENT, kernelName: name) == name)
            #expect(AgentExecutableIdentity.matches("/old-install/\(name)", name))
            #expect(AgentExecutableIdentity.matches(name, "/old-install/\(name)"))
            #expect(!AgentExecutableIdentity.matches("/first/\(name)", "/second/\(name)"))
            #expect(!AgentExecutableIdentity.matches("/old-install/\(name)-other", name))
        }

        @Test(arguments: [EACCES, EPERM, ESRCH, EIO])
        func otherErrorsNeverUseTheName(_ error: Int32) {
            #expect(AgentExecutableIdentity.resolve(path: nil, errorCode: error, kernelName: "codex") == nil)
        }

        @Test(arguments: ["", "codex-fake", "not-codex", "2.1.310", "node", "zsh", "codex\n", "/tmp/codex"])
        func ambiguousNamesRemainRejected(_ name: String) {
            #expect(AgentExecutableIdentity.resolve(path: nil, errorCode: ENOENT, kernelName: name) == nil)
            #expect(!AgentExecutableIdentity.matches("/install/codex", name))
        }

        @Test
        func readablePathRemainsAuthoritative() {
            #expect(AgentExecutableIdentity.resolve(path: "/install/other", errorCode: 0, kernelName: "codex") == "/install/other")
            #expect(AgentExecutableIdentity.resolve(path: nil, errorCode: 0, kernelName: "codex") == nil)
        }
    }
#endif
