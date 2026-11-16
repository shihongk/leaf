import AppKit

@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {
    /// Current text (kept in sync with the editor while in edit mode).
    var text: String = ""
    /// Bytes last read from or written to disk; used to ignore our own saves and no-op events.
    private var lastDiskData: Data?
    private var watcher: FileWatcher?
    /// Disk content that changed while the document had unsaved edits (conflict pending).
    private(set) var pendingDiskData: Data?

    var windowController: DocumentWindowController? {
        windowControllers.first as? DocumentWindowController
    }

    override class var autosavesInPlace: Bool { false }
    override class var autosavesDrafts: Bool { false }
    override class var preservesVersions: Bool { false }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController())
    }

    override var fileURL: URL? {
        didSet { if oldValue != fileURL { startWatching() } }
    }

    // MARK: Reading and writing

    override func read(from data: Data, ofType typeName: String) throws {
        text = Self.decode(data)
        lastDiskData = data
        windowController?.documentTextReplaced()
    }

    override func data(ofType typeName: String) throws -> Data {
        windowController?.syncTextFromEditor()
        let data = Data(text.utf8)
        lastDiskData = data
        return data
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil {
                self?.pendingDiskData = nil
                self?.windowController?.hideConflictBar()
            }
            completionHandler(error)
        }
    }

    override func close() {
        watcher?.stop()
        watcher = nil
        super.close()
    }

    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) {
            return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        if let s = String(data: data, encoding: .utf16) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Watching for outside changes

    private func startWatching() {
        watcher?.stop()
        watcher = nil
        guard let url = fileURL else { return }
        watcher = FileWatcher(url: url) { [weak self] in self?.diskMayHaveChanged() }
    }

    private func diskMayHaveChanged() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        if data == lastDiskData || data == pendingDiskData { return }
        if isDocumentEdited {
            pendingDiskData = data
            windowController?.showConflictBar()
        } else {
            apply(diskData: data, url: url)
        }
    }

    private func apply(diskData data: Data, url: URL) {
        text = Self.decode(data)
        lastDiskData = data
        pendingDiskData = nil
        fileModificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        undoManager?.removeAllActions()
        updateChangeCount(.changeCleared)
        windowController?.documentTextReplaced()
    }

    /// Conflict bar: "Reload" discards local edits and loads the disk version.
    func reloadFromDisk() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        windowController?.hideConflictBar()
        apply(diskData: data, url: url)
    }

    /// Conflict bar: "Keep mine" keeps the edits; the next save overwrites the disk version
    /// without NSDocument's "changed by another application" warning.
    func keepMine() {
        if let d = pendingDiskData { lastDiskData = d }
        pendingDiskData = nil
        if let url = fileURL {
            fileModificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        windowController?.hideConflictBar()
    }
}
