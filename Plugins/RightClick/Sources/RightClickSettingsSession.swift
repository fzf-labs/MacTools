import Foundation
import Combine

/// Shared editing session with automatic persistence and recoverable save failures.
@MainActor
final class RightClickSettingsSession: ObservableObject {
    @Published var configuration: RightClickConfiguration { didSet { if !isReloading { saveDraft() } } }
    @Published var error: String? { didSet { needsSaveRetry = false } }
    @Published var needsSaveRetry = false
    @Published var isWorking = false
    let fileURL: URL
    var onPersist: (() -> Void)?
    private var isReloading = false
    private var observer: NSObjectProtocol?

    init(configuration: RightClickConfiguration? = nil, fileURL: URL = RightClickConfigurationStore.configFileURL) {
        self.fileURL = fileURL
        self.configuration = configuration ?? RightClickConfigurationStore.load(from: fileURL)
        startObserving()
    }

    func startObserving() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("MacTools.RightClickConfigurationChanged"), object: fileURL.path, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.error == nil else { return }
                self.reload()
            }
        }
    }

    func stopObserving() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }

    func reload() {
        isReloading = true
        configuration = RightClickConfigurationStore.load(from: fileURL)
        isReloading = false
    }

    func saveDraft() {
        var value = configuration
        let current = RightClickConfigurationStore.load(from: fileURL)
        value.menuEnabled = current.menuEnabled
        value.preferredLanguages = current.preferredLanguages
        value.undoAvailable = current.undoAvailable
        guard RightClickConfigurationStore.save(value, to: fileURL) else {
            error = "Cannot save settings. Your changes are kept for retry."
            needsSaveRetry = true
            return
        }
        error = nil
        onPersist?()
    }
}
