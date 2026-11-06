#if os(macOS)
    import AppKit
    import Darwin
    import Dependencies
    import DependenciesMacros
    import Foundation

    @DependencyClient
    struct InstallerQuitRequestClient: Sendable {
        var rejectionReason: @MainActor @Sendable () -> String? = { nil }
    }

    extension InstallerQuitRequestClient: DependencyKey {
        static let liveValue = Self(rejectionReason: {
            @Dependency(\.date.now) var now
            let event = NSAppleEventManager.shared().currentAppleEvent
            let sender = event?.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value
            return rejectionReason(event: event, now: now, senderPID: sender) { pid in
                kill(pid, 0) == 0 || errno == EPERM
            }
        })
        static let testValue = Self(rejectionReason: { nil })

        /// Installer scripts send this optional parameter as epoch seconds.
        static let deadlineKeyword: AEKeyword = 0x6378646C // cxdl

        @MainActor
        static func rejectionReason(event: NSAppleEventDescriptor?, now: Date, senderPID: Int32?, isProcessRunning: (Int32) -> Bool) -> String? {
            guard
                let event, event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
                let deadline = event.paramDescriptor(forKeyword: deadlineKeyword) else { return nil }
            guard let raw = deadline.stringValue, let expires = TimeInterval(raw), expires.isFinite else {
                return "Installer Quit request has an invalid deadline."
            }
            guard expires > now.timeIntervalSince1970 else {
                return "Installer Quit request expired before cleanup started."
            }
            guard
                let pid = senderPID,
                pid > 0, isProcessRunning(pid) else {
                return "Installer Quit request sender is no longer running."
            }
            return nil
        }
    }
#endif
