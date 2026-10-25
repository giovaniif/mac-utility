import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay, noWindow, nothingCaptured

    var errorDescription: String? {
        switch self {
        case .noDisplay: "Couldn't find that display"
        case .noWindow: "That window is gone"
        case .nothingCaptured: "Nothing was captured"
        }
    }
}

/// ScreenCaptureKit filter and geometry for a `CaptureTarget`.
struct CaptureContent {
    let filter: SCContentFilter
    /// Region of the display in points, top-left origin. Nil captures it all.
    let sourceRect: CGRect?
    let pointSize: CGSize
    let scale: CGFloat

    var pixelWidth: Int { Int((pointSize.width * scale).rounded()) }
    var pixelHeight: Int { Int((pointSize.height * scale).rounded()) }

    @MainActor
    /// `windowAsRegion` captures a window's frame on its display instead of
    /// the window alone, so floating extras like the camera bubble show up.
    static func make(
        for target: CaptureTarget,
        excluding excludedIDs: [CGWindowID] = [],
        windowAsRegion: Bool = false
    ) async throws -> CaptureContent {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        if !windowAsRegion, case let .window(id, rect) = target {
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.noWindow }
            let scale = target.screen?.backingScaleFactor ?? 2
            return CaptureContent(
                filter: SCContentFilter(desktopIndependentWindow: window),
                sourceRect: nil,
                pointSize: rect.size,
                scale: scale
            )
        }

        guard let screen = target.screen,
              let display = content.displays.first(where: { $0.displayID == screen.displayID })
        else { throw CaptureError.noDisplay }
        let excluded = content.windows.filter { excludedIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let frame = screen.frame
        let rect = target.rect.intersection(frame)
        let sourceRect: CGRect? = if case .display = target {
            nil
        } else {
            CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        return CaptureContent(filter: filter, sourceRect: sourceRect, pointSize: rect.size, scale: screen.backingScaleFactor)
    }
}

/// New captures wait in a cache folder while their preview is up, so ones
/// you only copy, drag or dismiss never take disk space. Save moves them to
/// the save folder: the Desktop, or
/// `defaults write com.giovani.MacUtility captureFolder <path>`.
enum CaptureFiles {
    static var folder: URL {
        if let path = UserDefaults.standard.string(forKey: "captureFolder") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL.desktopDirectory
    }

    static let pendingFolder = URL.cachesDirectory.appending(path: "com.giovani.MacUtility/Captures", directoryHint: .isDirectory)

    static func newURL(prefix: String, ext: String) -> URL {
        try? FileManager.default.createDirectory(at: pendingFolder, withIntermediateDirectories: true)
        return uniqueURL(in: pendingFolder, base: "\(prefix) \(timestamp())", ext: ext)
    }

    static func isPending(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(pendingFolder.standardizedFileURL.path)
    }

    /// Deletes a capture that was never saved.
    static func discard(_ url: URL) {
        guard isPending(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Clears captures left from the last run (dragged or copied recordings
    /// stay until then, since the drop or paste may still read the file).
    static func clearPending() {
        try? FileManager.default.removeItem(at: pendingFolder)
    }

    static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var url = folder.appending(path: "\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return url
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}
