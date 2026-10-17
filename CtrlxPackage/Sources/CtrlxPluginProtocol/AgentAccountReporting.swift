import CtrlxNetworking
import Foundation

/// Optional account/entitlement reporting. Implementations own provider-specific
/// discovery and authentication; callers never receive credentials.
public protocol AgentAccountReporting: PluginCore {
    func dashboardAccounts() async -> [DashboardAccount]
}
