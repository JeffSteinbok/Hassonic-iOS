#if DEBUG
import Foundation

/// Watches the folder holding the injected dashboard so a file pushed by
/// `scripts/inject_config.py --watch` reaches the screen without a relaunch.
///
/// The watch is on the directory rather than on the override file itself. The
/// inject script replaces the override atomically, so the file a source was
/// opened against is a dead inode after the first save; a directory source
/// survives that, and is also the only thing that can see the very first
/// injection, when the override does not exist yet.
final class DashboardOverrideWatcher {
    private let source: any DispatchSourceFileSystemObject

    /// Returns nil when the directory cannot be opened, which in practice means
    /// it does not exist yet — there is nothing to watch and nothing to report.
    init?(directoryURL: URL, onChange: @escaping @Sendable () -> Void) {
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: DispatchQueue(label: "\(Bundle.main.bundleIdentifier ?? "Hassonic").dashboard-override")
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }

        self.source = source
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
#endif
