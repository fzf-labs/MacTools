import Foundation
import MacToolsPluginKit

/// Destination-only endpoint grants. Import cannot attach an existing credential to a new service.
@MainActor
struct PortableCredentialAuthorization {
    static let key = "preferences-backup.credential-endpoints.v1"
    let storage: any PluginStorage

    static var field: PortablePreferenceField {
        .data(Data("{}".utf8), maximumBytes: 262_144) { data in
            guard let grants = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
            return grants.count <= 256 && grants.allSatisfy {
                validGrant(profileID: $0.key, endpoint: $0.value)
            }
        }
    }

    // These destination-only grants retain URL components supported by existing local clients.
    // Portable payloads still use the stricter endpoint validator and cannot supply this map.
    private static func validGrant(profileID: String, endpoint: String) -> Bool {
        guard PortablePreferencesValidation.identifier(profileID), endpoint.utf8.count <= 262_144,
              let url = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host?.isEmpty == false, url.url != nil else { return false }
        return url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http"
    }

    var isInitialized: Bool {
        guard let data = storage.data(forKey: Self.key) else { return false }
        return Self.field.accepts(.data(data))
    }

    struct Replacement {
        /// Nil covers every grant sharing one key, as in AI Assistant.
        let profileIDs: Set<String>?
        let load: () throws -> String?
        let save: () throws -> Void

        func covers(_ profileID: String) -> Bool { profileIDs?.contains(profileID) ?? true }
    }

    /// Keep key writes quarantined until profile settings and final grants commit together.
    /// On any failure, restore only previous grants backed by a verified unchanged secret.
    func replaceCredentials(
        _ replacements: [Replacement],
        authorizing endpoints: [String: String],
        values: [String: PortablePreferenceValue],
        store: PortablePreferencesStore
    ) throws {
        guard store.recover() else { throw CocoaError(.fileWriteUnknown) }
        guard !replacements.isEmpty else {
            guard store.commit(values) else { throw CocoaError(.fileWriteUnknown) }
            return
        }
        let previousGrants = grants
        let previousKeys = replacements.map { try? $0.load() }
        let retainedGrants = previousGrants.filter { profileID, _ in
            !replacements.contains { $0.covers(profileID) }
        }
        guard let revoked = try? JSONEncoder().encode(retainedGrants),
              store.commit([Self.key: .data(revoked)]) else { throw CocoaError(.fileWriteUnknown) }
        do {
            for replacement in replacements { try replacement.save() }
            let authorized = endpoints.filter { Self.validGrant(profileID: $0.key, endpoint: $0.value) }
            let finalGrants = retainedGrants.merging(authorized, uniquingKeysWith: { _, local in local })
            var candidate = values
            candidate[Self.key] = .data(try JSONEncoder().encode(finalGrants))
            guard store.commit(candidate) else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            var recovered = retainedGrants
            for (replacement, previousKey) in zip(replacements, previousKeys) {
                guard let previousKey, let currentKey = try? replacement.load(), currentKey == previousKey else { continue }
                recovered.merge(previousGrants.filter { replacement.covers($0.key) }, uniquingKeysWith: { old, _ in old })
            }
            if let data = try? JSONEncoder().encode(recovered) {
                _ = store.commit([Self.key: .data(data)])
            }
            throw error
        }
    }

    private var grants: [String: String] {
        storage.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    func allows(profileID: String, baseURL: String) -> Bool {
        guard let granted = grants[profileID] else { return false }
        return canonical(granted) == canonical(baseURL)
    }

    /// Call before any import, once for existing destination profiles; no Keychain access.
    func seedIfNeeded(profiles: [String: String], store: PortablePreferencesStore) -> Bool {
        guard storage.object(forKey: Self.key) == nil else { return isInitialized }
        guard let data = try? JSONEncoder().encode(profiles.filter { Self.validGrant(profileID: $0.key, endpoint: $0.value) }) else { return false }
        return store.commit([Self.key: .data(data)])
    }

    private func canonical(_ endpoint: String) -> String {
        guard var components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { return endpoint }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string ?? endpoint
    }
}
