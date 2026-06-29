import Foundation

/// Watches a directory for content changes (files added / written / removed)
/// using a kqueue-backed DispatchSource. Cheap and immediate; the app also
/// runs a periodic timer so time-based decay is re-evaluated without changes.
///
/// A kqueue fd is bound to the directory's inode, so if the directory is
/// deleted and recreated the source goes silent. We detect that (.delete /
/// .rename on the watched fd) and rebuild the source on the new inode.
final class DirectoryWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    init?(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        guard start() else { return nil }
    }

    @discardableResult
    private func start() -> Bool {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.source?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) {
                self.reopen()      // directory vanished; rebind to the new inode
            }
            self.onChange()
        }
        let descriptor = fd
        src.setCancelHandler { close(descriptor) }
        source = src
        src.resume()
        return true
    }

    private func reopen() {
        source?.cancel()           // closes the old fd via the cancel handler
        source = nil
        fd = -1
        // Recreate the directory (if needed) and a fresh source. Retry shortly
        // if the directory isn't back yet.
        if !start() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.start()
            }
        }
    }

    deinit {
        source?.cancel()
    }
}
