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

    private static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let ch = it.next() {
            guard ch == "\\" else { out.append(ch); continue }
            switch it.next() {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\\": out.append("\\")
            case let other?: out.append("\\"); out.append(other)
            case nil: out.append("\\")
            }
        }
        return out
    }

    private static func run(_ cmd: String) {
        if cmd == "settings" { (NSApp.delegate as? AppDelegate)?.showSettings(nil); return }
        if cmd == "new" { NSDocumentController.shared.newDocument(nil); return }
        guard let c = front else { return }
        if cmd.hasPrefix("pasteText:") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(cmd.dropFirst("pasteText:".count)).replacingOccurrences(of: "\\n", with: "\n"), forType: .string)
            c.debugPaste()
            return
        }
        if cmd.hasPrefix("insert:") {
            // "\n" and "\t" escapes become newline / tab; "\\" is a literal backslash.
            c.debugInsert(unescape(String(cmd.dropFirst("insert:".count))))
            return
        }
        if cmd.hasPrefix("saveTo:") {
            // Save the front document to a path without a panel (test-only).
            let url = URL(fileURLWithPath: String(cmd.dropFirst("saveTo:".count)))
            (c.document as? NSDocument)?.save(to: url, ofType: "net.daringfireball.markdown",
                                               for: .saveAsOperation) { _ in }
            return
        }
        if cmd.hasPrefix("clickCheckbox:"), let n = Int(cmd.dropFirst("clickCheckbox:".count)) {
            c.debugClickCheckbox(n)
            return
        }
        switch cmd {
        case "dblclick": c.debugDoubleClick()
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
