import Foundation

enum FileBrowserOfficeDocument {
    static let maximumPreviewBytes = 32 * 1_024 * 1_024

    static func supports(path: String) -> Bool {
        switch (path as NSString).pathExtension.lowercased() {
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx": true
        default: false
        }
    }
}
