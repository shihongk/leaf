import AppKit

/// Test-only remote control, active only when the app is launched with LEAF_DEBUG=1.
/// Commands arrive as distributed notifications named "local.leaf.debug" whose object is
/// the command string (see tools/leafctl.swift). State is written to LEAF_DEBUG_STATE.
enum DebugHooks {
    static func install() {
        guard ProcessInfo.processInfo.environment["LEAF_DEBUG"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.leaf.debug"), object: nil, queue: .main
        ) { note in
            guard let cmd = note.object as? String else { return }
            run(cmd)
        }
    }

    private static var front: DocumentWindowController? {
        NSApp.orderedWindows.lazy.compactMap { $0.windowController as? DocumentWindowController }.first
    }

    private static func run(_ cmd: String) {
        if cmd == "settings" { (NSApp.delegate as? AppDelegate)?.showSettings(nil); return }
        if cmd == "new" { NSDocumentController.shared.newDocument(nil); return }
        guard let c = front else { return }
        if cmd.hasPrefix("insert:") {
            c.debugInsert(String(cmd.dropFirst("insert:".count)))
            return
        }
        switch cmd {
        case "toggleEdit": c.toggleEditMode(nil)
        case "save": (c.document as? NSDocument)?.save(nil as Any?)
        case "keepMine": (c.document as? MarkdownDocument)?.keepMine()
        case "reload": (c.document as? MarkdownDocument)?.reloadFromDisk()
        case "undo": c.document?.undoManager?.undo()
        case "zoomIn": c.zoomIn(nil)
        case "zoomOut": c.zoomOut(nil)
        case "zoomReset": c.zoomActualSize(nil)
        case "state":
            guard let path = ProcessInfo.processInfo.environment["LEAF_DEBUG_STATE"] else { return }
            let s = c.debugState()
            if let data = try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        default: break
        }
    }
}
