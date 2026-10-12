import Foundation

public enum SimulatorOperation: String, CaseIterable, Sendable {
    case inventory, config, resources, identity, devices, open, status, metrics, logs, crashes, show
    case snapshot, wait, tap, swipe, drag, pinch, rotate, key, button, paste, install, uninstall, launch, terminate
    case storage, erase, delete
    case location, appearance, privacy, push, screenshot, claim, close
    case displayMode = "display-mode"
    case longPress = "long-press"
    case openURL = "open-url"
    case recordStart = "record-start"
    case recordStop = "record-stop"
    case recordStatus = "record-status"
}

public enum SimulatorBatchLimits {
    public static let maximumActions = 16
    public static let maximumRequestBytes = 64000
    public static let maximumResponseBytes = 32 * 1024 * 1024
    public static let admissionSeconds = 60
    public static let transportSeconds = 310
}
