import Foundation
import MacToolsPluginKit

struct TranslatorProviderProfile: Codable, Equatable, Identifiable, Sendable {
    static let defaultID = "openai"
    static let defaultName = "OpenAI"

    var id: String
    var name: String
    var isEnabled: Bool
    var baseURL: String
    var model: String
    var promptTemplate: String

    init(
        id: String = UUID().uuidString,
        name: String,
        isEnabled: Bool = true,
        baseURL: String = OpenAICompatibleConfiguration.defaultBaseURL,
        model: String = OpenAICompatibleConfiguration.defaultModel,
        promptTemplate: String = OpenAICompatibleConfiguration.defaultPromptTemplate
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.model = model
        self.promptTemplate = promptTemplate
    }

    static func defaultProfile(
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> TranslatorProviderProfile {
        TranslatorProviderProfile(
            id: defaultID,
            name: defaultName,
            isEnabled: true,
            promptTemplate: OpenAICompatibleConfiguration.defaultPromptTemplate(localization: localization)
        )
    }

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var configuration: OpenAICompatibleConfiguration {
        OpenAICompatibleConfiguration(
            baseURL: baseURL,
            model: model,
            promptTemplate: promptTemplate
        )
    }

    var validationError: TranslatorProviderProfileValidationError? {
        if normalizedName.isEmpty {
            return .blankName
        }

        if let configurationError = configuration.validationError {
            return .configuration(configurationError)
        }

        return nil
    }

    func normalized() -> TranslatorProviderProfile {
        var copy = self
        copy.name = normalizedName
        copy.baseURL = configuration.normalizedBaseURL
        copy.model = configuration.normalizedModel
        return copy
    }
}

enum TranslatorProviderProfileValidationError: Error, Equatable, Sendable {
    case blankName
    case configuration(OpenAICompatibleConfigurationError)
}

extension TranslatorProviderProfileValidationError: LocalizedError {
    var errorDescription: String? {
        errorDescription()
    }

    func errorDescription(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .blankName:
            return localization.string("providerProfile.error.blankName", defaultValue: "服务名称不能为空。")
        case let .configuration(error):
            return error.errorDescription(localization: localization)
        }
    }
}

@MainActor
struct TranslatorProviderProfileStore {
    let storage: PluginStorage
    let localization: PluginLocalization

    init(
        storage: PluginStorage,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.storage = storage
        self.localization = localization
    }

    func loadProfiles() -> [TranslatorProviderProfile] {
        if let data = storage.data(forKey: TranslatorConstants.StorageKey.providerProfiles),
           let profiles = try? JSONDecoder().decode([TranslatorProviderProfile].self, from: data),
           !profiles.isEmpty {
            return profiles
        }

        return [legacyProfile()]
    }

    func saveProfiles(_ profiles: [TranslatorProviderProfile]) throws {
        let normalizedProfiles = profiles.map { $0.normalized() }
        let data = try JSONEncoder().encode(normalizedProfiles)
        let previous = storage.object(forKey: TranslatorConstants.StorageKey.providerProfiles)
        storage.set(data, forKey: TranslatorConstants.StorageKey.providerProfiles)
        guard storage.data(forKey: TranslatorConstants.StorageKey.providerProfiles) == data else {
            if let previous { storage.set(previous, forKey: TranslatorConstants.StorageKey.providerProfiles) }
            else { storage.removeObject(forKey: TranslatorConstants.StorageKey.providerProfiles) }
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func makeNewProfile(existingProfiles: [TranslatorProviderProfile]) -> TranslatorProviderProfile {
        var index = existingProfiles.count + 1
        var name = "OpenAI \(index)"
        let existingNames = Set(existingProfiles.map(\.normalizedName))

        while existingNames.contains(name) {
            index += 1
            name = "OpenAI \(index)"
        }

        return TranslatorProviderProfile(
            name: name,
            isEnabled: false,
            promptTemplate: OpenAICompatibleConfiguration.defaultPromptTemplate(localization: localization)
        )
    }

    private func legacyProfile() -> TranslatorProviderProfile {
        TranslatorProviderProfile(
            id: TranslatorProviderProfile.defaultID,
            name: TranslatorProviderProfile.defaultName,
            isEnabled: true,
            baseURL: storage.string(forKey: TranslatorConstants.StorageKey.openAIBaseURL)
                ?? OpenAICompatibleConfiguration.defaultBaseURL,
            model: storage.string(forKey: TranslatorConstants.StorageKey.openAIModel)
                ?? OpenAICompatibleConfiguration.defaultModel,
            promptTemplate: storage.string(forKey: TranslatorConstants.StorageKey.openAIPromptTemplate)
                ?? OpenAICompatibleConfiguration.defaultPromptTemplate(localization: localization)
        )
    }
}
