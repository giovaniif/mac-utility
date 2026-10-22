import Foundation

/// One captured pasteboard entry. Image bytes live in files next to the
/// history; everything else is stored inline.
struct ClipboardItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case text, richText, image, files
    }

    var id = UUID()
    var kind: Kind
    /// Plain text, also the fallback for rich text and the search key.
    var text: String?
    var rtf: Data?
    var html: Data?
    /// File names inside the images folder.
    var imageFile: String?
    var thumbnailFile: String?
    var fileURLs: [URL]?
    var sourceBundleID: String?
    var date = Date()
    var pinned = false
    /// Identity used to collapse duplicates.
    var fingerprint: String

    var searchText: String {
        switch kind {
        case .text, .richText: text ?? ""
        case .image: "image"
        case .files: (fileURLs ?? []).map(\.lastPathComponent).joined(separator: " ")
        }
    }
}
