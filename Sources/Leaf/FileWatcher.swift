import Foundation

/// Watches a single file for changes. Handles both in-place writes (`echo >> file`) and
/// atomic replacement (write temp file + rename over the original), which most editors and
/// AI tools use. Atomic replacement invalidates the watched inode, so the watcher re-arms on
/// the new file; the parent directory is watched too as a belt-and-braces signal.
/// The callback is debounced and may fire spuriously: callers must compare content.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private var rearmAttempts = 0
    private var stopped = false

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        armFile()
        armDirectory()
    }

    deinit { stop() }

    func stop() {
        stopped = true
        debounce?.cancel()
        fileSource?.cancel(); fileSource = nil
        dirSource?.cancel(); dirSource = nil
    }

    private func armFile() {
        guard !stopped else { return }
        fileSource?.cancel(); fileSource = nil
        let fd = open(url.path, O_EVTONLY)
        if fd < 0 {
            // File may be mid-replacement. Retry for a few seconds.
            if rearmAttempts < 50 {
                rearmAttempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.armFile() }
            }
            return
        }
        rearmAttempts = 0
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke, .attrib], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let ev = src.data
            if !ev.intersection([.delete, .rename, .revoke]).isEmpty {
                // The path now points at a different inode (or nothing yet): re-arm.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.armFile() }
            }
            self.scheduleChange()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileSource = src
    }

    private func armDirectory() {
        let dir = url.deletingLastPathComponent()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // An entry in the folder changed; if our file was replaced, re-arm on the new inode.
            self.armFile()
            self.scheduleChange()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }

    private func scheduleChange() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }
}
