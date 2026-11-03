import CryptoKit
import Foundation
import MacToolsPluginKit

nonisolated enum LauncherIdentity {
    static func action(_ reference: ActionReference) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(reference)) ?? Data(reference.key.id.utf8)
        return "action." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
