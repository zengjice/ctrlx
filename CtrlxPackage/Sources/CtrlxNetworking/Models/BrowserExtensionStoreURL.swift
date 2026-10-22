import Foundation

public enum BrowserExtensionStoreURL {
    public static let home = "https://chromewebstore.google.com/"

    public static func isStore(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.scheme == "https" && url.host == "chromewebstore.google.com"
            && url.user == nil && url.password == nil && url.port == nil
    }

    public static func extensionID(from value: String) -> String? {
        guard isStore(value), let url = URL(string: value) else { return nil }
        let parts = url.path.split(separator: "/")
        guard
            (2...3).contains(parts.count), parts.first == "detail", let id = parts.last,
            id.utf8.count == 32, id.utf8.allSatisfy({ (97...112).contains($0) }) else { return nil }
        return String(id)
    }
}
