import CoreServices
import Foundation

final class WallpaperFolderObserver: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor @Sendable () -> Void
    var isWatching: Bool { stream != nil }

    init(urls: [URL], onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
        guard !urls.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            let observer = Unmanaged<WallpaperFolderObserver>.fromOpaque(info).takeUnretainedValue()
            let onChange = observer.onChange
            Task { @MainActor in onChange() }
        }, &context, urls.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        1, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        }
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
