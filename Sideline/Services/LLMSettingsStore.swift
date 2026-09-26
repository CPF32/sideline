import Foundation

struct LLMModelOption: Identifiable, Hashable {
    let id: String
    let title: String
    /// Short relative cost label for the picker.
    let costLabel: String
    /// Used for cheapest-first sorting (lower is cheaper).
    var sortPrice: Double = 0
}

enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case openAI = "openai"
    case anthropic = "anthropic"
    case google = "google"
    case openRouter = "openrouter"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google"
        case .openRouter: return "OpenRouter"
        }
    }

    var keychainKey: KeychainStore.Key {
        switch self {
        case .openAI: return .llmOpenAI
        case .anthropic: return .llmAnthropic
        case .google: return .llmGoogle
        case .openRouter: return .llmOpenRouter
        }
    }

    /// Offline / fetch-failed fallback, cheapest first.
    var fallbackModels: [LLMModelOption] {
        switch self {
        case .openAI:
            return [
                .init(id: "gpt-4o-mini", title: "GPT-4o mini", costLabel: "Lowest $", sortPrice: 0),
                .init(id: "gpt-4.1-mini", title: "GPT-4.1 mini", costLabel: "Low $", sortPrice: 1),
                .init(id: "gpt-4o", title: "GPT-4o", costLabel: "Higher $", sortPrice: 2),
                .init(id: "gpt-4.1", title: "GPT-4.1", costLabel: "Highest $", sortPrice: 3)
            ]
        case .anthropic:
            return [
                .init(id: "claude-haiku-4-5-20251001", title: "Haiku 4.5", costLabel: "Lowest $", sortPrice: 0),
                .init(id: "claude-sonnet-4-20250514", title: "Sonnet 4", costLabel: "Mid $", sortPrice: 1),
                .init(id: "claude-opus-4-20250514", title: "Opus 4", costLabel: "Highest $", sortPrice: 2)
            ]
        case .google:
            return [
                .init(id: "gemini-2.5-flash-lite", title: "Gemini 2.5 Flash-Lite", costLabel: "Lowest $", sortPrice: 0),
                .init(id: "gemini-2.0-flash-lite", title: "Gemini 2.0 Flash-Lite", costLabel: "Low $", sortPrice: 1),
                .init(id: "gemini-2.0-flash", title: "Gemini 2.0 Flash", costLabel: "Low $", sortPrice: 2),
                .init(id: "gemini-2.5-flash", title: "Gemini 2.5 Flash", costLabel: "Low $", sortPrice: 3),
                .init(id: "gemini-2.5-pro", title: "Gemini 2.5 Pro", costLabel: "Higher $", sortPrice: 4)
            ]
        case .openRouter:
            return [
                .init(id: "google/gemini-2.5-flash-lite", title: "Gemini 2.5 Flash-Lite", costLabel: "Lowest $", sortPrice: 0),
                .init(id: "openai/gpt-4o-mini", title: "GPT-4o mini", costLabel: "Low $", sortPrice: 1),
                .init(id: "google/gemini-2.5-flash", title: "Gemini 2.5 Flash", costLabel: "Low $", sortPrice: 2),
                .init(id: "anthropic/claude-haiku-4.5", title: "Claude Haiku 4.5", costLabel: "Mid $", sortPrice: 3),
                .init(id: "anthropic/claude-sonnet-4", title: "Claude Sonnet 4", costLabel: "Higher $", sortPrice: 4)
            ]
        }
    }

    var defaultModel: String { fallbackModels.first?.id ?? "" }

    var setupHint: String {
        switch self {
        case .openAI:
            return "Live models load with your OpenAI key. Selection is saved in the on-device database."
        case .anthropic:
            return "Live models load with your Anthropic key. Selection is saved in the on-device database."
        case .google:
            return "Live models load with your Google key. Selection is saved in the on-device database."
        case .openRouter:
            return "Live OpenRouter catalog sorted by price. Selection is saved in the on-device database."
        }
    }
}

@MainActor
final class LLMSettingsStore: ObservableObject {
    @Published var provider: LLMProvider {
        didSet {
            guard !isHydrating, provider != oldValue else { return }
            applyModel(modelsByProvider[provider.rawValue] ?? provider.defaultModel, persist: true)
            reloadKeyDraft()
        }
    }

    @Published var model: String {
        didSet {
            guard !isHydrating, model != oldValue else { return }
            modelsByProvider[provider.rawValue] = model
            persistHandler?()
        }
    }

    @Published var apiKeyDraft: String = ""
    @Published private(set) var keySaveMessage: String?
    @Published private(set) var keyIsSaved: Bool = false
    @Published private(set) var liveModels: [LLMModelOption] = []
    @Published private(set) var isLoadingModels = false
    @Published private(set) var modelsSourceLabel = "Using offline list"
    @Published private(set) var modelsError: String?

    /// Per-provider last model id (persisted via SwiftData through `persistHandler`).
    private(set) var modelsByProvider: [String: String] = [:]

    private var fetchTask: Task<Void, Never>?
    private var isHydrating = true
    private var persistHandler: (() -> Void)?

    init() {
        KeychainStore.set(nil, for: .llmTypeSafe)
        provider = .openAI
        liveModels = LLMProvider.openAI.fallbackModels
        model = LLMProvider.openAI.defaultModel
        modelsByProvider = [LLMProvider.openAI.rawValue: LLMProvider.openAI.defaultModel]
        apiKeyDraft = ""
        keyIsSaved = false
        isLoadingModels = false
        modelsSourceLabel = "Using offline list"
        modelsError = nil
        isHydrating = false
    }

    /// Called from AppState after SwiftData preferences are loaded.
    func hydrate(providerRaw: String, model: String, modelsByProvider: [String: String]) {
        isHydrating = true
        var map = modelsByProvider
        let resolvedProvider = LLMProvider(rawValue: providerRaw == "typesafe" ? "openai" : providerRaw) ?? .openAI
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = trimmed.isEmpty
            ? (map[resolvedProvider.rawValue] ?? resolvedProvider.defaultModel)
            : trimmed
        if map[resolvedProvider.rawValue] == nil {
            map[resolvedProvider.rawValue] = resolvedModel
        }
        self.modelsByProvider = map
        provider = resolvedProvider
        liveModels = resolvedProvider.fallbackModels
        self.model = resolvedModel
        apiKeyDraft = KeychainStore.get(resolvedProvider.keychainKey) ?? ""
        keyIsSaved = !(KeychainStore.get(resolvedProvider.keychainKey) ?? "").isEmpty
        isHydrating = false
    }

    func bindPersistHandler(_ handler: @escaping () -> Void) {
        persistHandler = handler
    }

    var hasAPIKey: Bool {
        !(KeychainStore.get(provider.keychainKey) ?? "").isEmpty
    }

    var maskedKeyHint: String {
        guard let key = KeychainStore.get(provider.keychainKey), key.count >= 8 else {
            return hasAPIKey ? "Key on device" : "No key saved"
        }
        return "Saved · …\(key.suffix(4))"
    }

    var pickerModels: [LLMModelOption] {
        liveModels.isEmpty ? provider.fallbackModels : liveModels
    }

    /// Human-readable label for agent activity / status (provider + friendly model title).
    var selectedModelLabel: String {
        let title = pickerModels.first(where: { $0.id == model })?.title
            ?? friendlyModelTitle(model)
        return "\(provider.displayName) · \(title)"
    }

    private func friendlyModelTitle(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown model" }
        if let slash = trimmed.lastIndex(of: "/") {
            return String(trimmed[trimmed.index(after: slash)...])
        }
        return trimmed
    }

    func clearSaveMessage() {
        keySaveMessage = nil
    }

    /// Wipe provider choice, model, drafts, and all LLM API keys from Keychain.
    func resetForAccountDeletion() {
        fetchTask?.cancel()
        fetchTask = nil
        KeychainStore.delete(.llmOpenAI)
        KeychainStore.delete(.llmAnthropic)
        KeychainStore.delete(.llmGoogle)
        KeychainStore.delete(.llmOpenRouter)
        KeychainStore.delete(.llmTypeSafe)
        isHydrating = true
        provider = .openAI
        liveModels = LLMProvider.openAI.fallbackModels
        model = LLMProvider.openAI.defaultModel
        modelsByProvider = [LLMProvider.openAI.rawValue: LLMProvider.openAI.defaultModel]
        isHydrating = false
        apiKeyDraft = ""
        keyIsSaved = false
        keySaveMessage = nil
        isLoadingModels = false
        modelsSourceLabel = "Using offline list"
        modelsError = nil
    }

    /// Switch provider and restore that provider's last saved model (or its default).
    func selectProvider(_ newProvider: LLMProvider) {
        guard newProvider != provider else { return }
        provider = newProvider
        refreshModels(preferCheapestIfInvalid: false)
    }

    func selectModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        applyModel(trimmed, persist: true)
    }

    /// Explicit flush used when the app backgrounds.
    func persistCurrentSelection() {
        modelsByProvider[provider.rawValue] = model
        persistHandler?()
    }

    func reloadKeyDraft() {
        apiKeyDraft = KeychainStore.get(provider.keychainKey) ?? ""
        keyIsSaved = hasAPIKey
        keySaveMessage = nil
        if !looksCompatible(model, with: provider) {
            applyModel(modelsByProvider[provider.rawValue] ?? provider.defaultModel, persist: true)
        }
    }

    @discardableResult
    func saveAPIKey() -> Bool {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.set(trimmed.isEmpty ? nil : trimmed, for: provider.keychainKey)
        let ok = (KeychainStore.get(provider.keychainKey) ?? "") == trimmed
            || (trimmed.isEmpty && KeychainStore.get(provider.keychainKey) == nil)
        keyIsSaved = hasAPIKey
        if trimmed.isEmpty {
            keySaveMessage = ok ? "API key cleared from Keychain." : "Couldn’t clear key — try again."
        } else {
            keySaveMessage = ok ? "API key saved to Keychain." : "Save failed — Keychain write didn’t stick."
        }
        refreshModels(preferCheapestIfInvalid: false)
        return ok
    }

    func resolvedAPIKey() -> String? {
        let key = KeychainStore.get(provider.keychainKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { return nil }
        return key
    }

    /// Pull live model list for the current provider. Never clobber a saved selection
    /// with the cheapest catalog entry.
    func refreshModels(preferCheapestIfInvalid: Bool = false) {
        fetchTask?.cancel()
        let currentProvider = provider
        let key = resolvedAPIKey()
        isLoadingModels = true
        modelsError = nil
        fetchTask = Task { @MainActor in
            let fetched = await LLMModelCatalog.fetch(provider: currentProvider, apiKey: key)
            guard !Task.isCancelled else { return }
            guard self.provider == currentProvider else {
                isLoadingModels = false
                return
            }
            let usedLive = fetched.map(\.id) != currentProvider.fallbackModels.map(\.id)
                || currentProvider == .openRouter
            liveModels = fetched.isEmpty ? currentProvider.fallbackModels : fetched

            let wanted = self.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if wanted.isEmpty {
                applyModel(liveModels.first?.id ?? currentProvider.defaultModel, persist: true)
            } else if liveModels.contains(where: { $0.id == wanted }) {
                modelsByProvider[currentProvider.rawValue] = wanted
                persistHandler?()
            } else if let fuzzy = fuzzyMatch(wanted, in: liveModels) {
                applyModel(fuzzy, persist: true)
            } else if preferCheapestIfInvalid, !looksCompatible(wanted, with: currentProvider) {
                applyModel(liveModels.first?.id ?? currentProvider.defaultModel, persist: true)
            }

            isLoadingModels = false
            if usedLive && !fetched.isEmpty {
                modelsSourceLabel = "Live · \(liveModels.count) models · cheapest first"
                modelsError = nil
            } else {
                modelsSourceLabel = key == nil && currentProvider != .openRouter
                    ? "Offline list — save an API key to load live models"
                    : "Offline fallback list"
                if key == nil && currentProvider != .openRouter {
                    modelsError = nil
                }
            }
        }
    }

    private func applyModel(_ id: String, persist: Bool) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        modelsByProvider[provider.rawValue] = trimmed
        if model != trimmed {
            model = trimmed
        } else if persist {
            persistHandler?()
        }
    }

    private func fuzzyMatch(_ wanted: String, in models: [LLMModelOption]) -> String? {
        let w = wanted.lowercased()
        guard !w.isEmpty else { return nil }
        if let exact = models.first(where: { $0.id.lowercased() == w })?.id { return exact }
        if let hit = models.first(where: {
            let id = $0.id.lowercased()
            return id.hasSuffix("/\(w)") || w.hasSuffix("/\(id)")
        })?.id {
            return hit
        }
        if let hit = models.first(where: { $0.title.lowercased() == w })?.id {
            return hit
        }
        return nil
    }

    private func looksCompatible(_ modelId: String, with provider: LLMProvider) -> Bool {
        let id = modelId.lowercased()
        switch provider {
        case .openAI:
            return id.hasPrefix("gpt") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4")
                || id.hasPrefix("chatgpt")
        case .anthropic:
            return id.contains("claude")
        case .google:
            return id.contains("gemini")
        case .openRouter:
            return !id.isEmpty
        }
    }
}
