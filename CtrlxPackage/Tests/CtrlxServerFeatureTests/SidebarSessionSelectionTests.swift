#if os(macOS)
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Sidebar session selection")
    struct SidebarSessionSelectionTests {
        @Test("Identical names on different Hosts are distinct selection targets")
        func hostScopedNames() {
            let selections: Set<SidebarSessionSelection> = [
                .local(sessionName: "codex"),
                .remote(hostID: "office", sessionName: "codex"),
                .remote(hostID: "home", sessionName: "codex"),
                .remote(hostID: "office", sessionName: "terminal"),
            ]
            #expect(selections.count == 4)
            #expect(selections.contains(.remote(hostID: "office", sessionName: "codex")))
        }
    }
#endif
