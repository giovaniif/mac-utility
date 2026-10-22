import AppKit
import os

/// Ties the watcher, store and picker panel together, and performs the paste.
@MainActor
final class ClipboardHistory {
    private let log = Logger(subsystem: "com.giovani.MacUtility", category: "clipboard")
    private let permissions: Permissions
    private let store = ClipboardStore()
    private let watcher: ClipboardWatcher
    private let panel: ClipboardPanel

    init(permissions: Permissions) {
        self.permissions = permissions
        watcher = ClipboardWatcher(store: store)
        panel = ClipboardPanel(store: store)
        panel.onCommand = { [weak self] command in
            switch command {
            case let .paste(item, plainText): self?.paste(item, plainText: plainText)
            }
        }
        watcher.start()
    }

    func toggle() {
        panel.isVisible ? panel.hide() : panel.show()
    }

    private func paste(_ item: ClipboardItem, plainText: Bool) {
        write(item, plainText: plainText)
        store.touch(item.id)
        panel.hide(animated: false)

        permissions.refresh()
        guard permissions.accessibility else {
            HUD.show("Copied. Grant Accessibility to paste")
            permissions.requestAccessibility()
            return
        }
        // Let the target app take key focus back before the keystroke lands.
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            Self.postCommandV()
        }
    }

    private func write(_ item: ClipboardItem, plainText: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if item.kind == .files, let urls = item.fileURLs, !plainText {
            pasteboard.writeObjects(urls as [NSURL])
            pasteboard.setData(Data(), forType: .macUtilityMarker)
            return
        }

        let entry = NSPasteboardItem()
        entry.setData(Data(), forType: .macUtilityMarker)
        switch item.kind {
        case .text, .richText:
            entry.setString(item.text ?? "", forType: .string)
            if !plainText {
                if let rtf = item.rtf { entry.setData(rtf, forType: .rtf) }
                if let html = item.html { entry.setData(html, forType: .html) }
            }
        case .image:
            if let name = item.imageFile, let png = try? Data(contentsOf: store.imageURL(name)) {
                entry.setData(png, forType: .png)
            }
        case .files:
            entry.setString((item.fileURLs ?? []).map(\.path).joined(separator: "\n"), forType: .string)
        }
        if !pasteboard.writeObjects([entry]) {
            log.error("pasteboard write failed")
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
