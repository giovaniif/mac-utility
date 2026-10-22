import AppKit
import CryptoKit
import os

extension NSPasteboard.PasteboardType {
    /// Tags our own writes so the watcher doesn't record them again.
    static let macUtilityMarker = Self("com.giovani.MacUtility.paste")
    static let concealed = Self("org.nspasteboard.ConcealedType")
    static let transient = Self("org.nspasteboard.TransientType")
}

/// Polls `NSPasteboard.general.changeCount` every 300 ms. macOS posts no
/// change notification for the pasteboard.
@MainActor
final class ClipboardWatcher {
    private let log = Logger(subsystem: "com.giovani.MacUtility", category: "clipboard")
    private let store: ClipboardStore
    private let pasteboard = NSPasteboard.general
    private var changeCount: Int
    private var timer: Timer?

    /// Bundle IDs never recorded. Override with
    /// `defaults write com.giovani.MacUtility clipboardExcludedApps -array <ids>`.
    private var excludedApps: Set<String> {
        let ids = UserDefaults.standard.stringArray(forKey: "clipboardExcludedApps")
            ?? ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess"]
        return Set(ids)
    }

    init(store: ClipboardStore) {
        self.store = store
        changeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != changeCount else { return }
        changeCount = count
        guard Feature.clipboardHistory.isEnabled else { return }

        let types = Set(pasteboard.types ?? [])
        if !types.isDisjoint(with: [.macUtilityMarker, .concealed, .transient]) { return }
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let source, excludedApps.contains(source) { return }

        if let item = capture(types: types, source: source) {
            store.add(item)
        }
    }

    private func capture(types: Set<NSPasteboard.PasteboardType>, source: String?) -> ClipboardItem? {
        if types.contains(.fileURL),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let fingerprint = "files:" + urls.map(\.path).joined(separator: "\n")
            return ClipboardItem(kind: .files, fileURLs: urls, sourceBundleID: source, fingerprint: fingerprint)
        }

        if types.contains(.png) || types.contains(.tiff), let png = readPNG() {
            return imageItem(png: png, source: source)
        }

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        let rtf = pasteboard.data(forType: .rtf)
        let html = pasteboard.data(forType: .html)
        let kind: ClipboardItem.Kind = rtf == nil && html == nil ? .text : .richText
        return ClipboardItem(kind: kind, text: text, rtf: rtf, html: html, sourceBundleID: source, fingerprint: "text:" + text)
    }

    private func readPNG() -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func imageItem(png: Data, source: String?) -> ClipboardItem? {
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let id = UUID()
        let imageName = "\(id.uuidString).png"
        let thumbName = "\(id.uuidString)-thumb.png"
        let thumb = Self.thumbnail(png: png, maxSide: 360)
        let imageURL = store.imageURL(imageName)
        let thumbURL = store.imageURL(thumbName)
        do {
            try png.write(to: imageURL, options: .atomic)
            try thumb?.write(to: thumbURL, options: .atomic)
        } catch {
            log.error("image write failed: \(error.localizedDescription)")
            return nil
        }
        return ClipboardItem(
            id: id,
            kind: .image,
            imageFile: imageName,
            thumbnailFile: thumb == nil ? nil : thumbName,
            sourceBundleID: source,
            fingerprint: "image:" + hash
        )
    }

    private static func thumbnail(png: Data, maxSide: CGFloat) -> Data? {
        guard let image = NSImage(data: png), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
