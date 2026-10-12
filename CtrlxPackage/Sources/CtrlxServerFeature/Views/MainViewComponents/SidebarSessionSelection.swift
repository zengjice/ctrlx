/// Session names are unique only within one Host.
enum SidebarSessionSelection: Hashable {
    case local(sessionName: String)
    case remote(hostID: String, sessionName: String)
}
