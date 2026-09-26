import Foundation
import SwiftData

/// Loads / saves the singleton `UserPreferences` SwiftData row.
/// Migrates once from legacy UserDefaults keys.
@MainActor
enum UserPreferencesStore {
    private static let migratedKey = "sideline.prefs.migratedToSwiftData"

    static func fetchOrCreate(in context: ModelContext) -> UserPreferences {
        let singletonId = UserPreferences.singletonId
        let descriptor = FetchDescriptor<UserPreferences>(
            predicate: #Predicate { $0.id == singletonId }
        )
        if let existing = try? context.fetch(descriptor).first {
            syncLegacyMirrors(from: existing)
            return existing
        }

        let prefs: UserPreferences
        if !UserDefaults.standard.bool(forKey: migratedKey) {
            prefs = migrateFromUserDefaults()
            UserDefaults.standard.set(true, forKey: migratedKey)
        } else {
            prefs = UserPreferences()
        }
        context.insert(prefs)
        try? context.save()
        syncLegacyMirrors(from: prefs)
        return prefs
    }

    static func save(_ prefs: UserPreferences, in context: ModelContext) {
        prefs.updatedAt = .now
        syncLegacyMirrors(from: prefs)
        try? context.save()
    }

    static func deleteAll(in context: ModelContext) {
        let rows = (try? context.fetch(FetchDescriptor<UserPreferences>())) ?? []
        for row in rows { context.delete(row) }
        try? context.save()
        UserDefaults.standard.removeObject(forKey: migratedKey)
    }

    static func encodeModelsByProvider(_ map: [String: String]) -> Data {
        (try? JSONEncoder().encode(map)) ?? Data("{}".utf8)
    }

    static func decodeModelsByProvider(_ data: Data) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Keep UserDefaults mirrors in sync for nonisolated readers (FantasyPros, Live Activity).
    private static func syncLegacyMirrors(from prefs: UserPreferences) {
        UserDefaults.standard.set(prefs.isDarkMode, forKey: "sideline.appearance.darkMode")
        UserDefaults.standard.set(prefs.liveActivityEnabled, forKey: LiveActivityManager.enabledKey)
        UserDefaults.standard.set(prefs.fantasyProsScoringRaw, forKey: "sideline.fantasypros.scoring")
        if let id = prefs.activeLeagueLinkId {
            UserDefaults.standard.set(id, forKey: "sideline.activeLeagueLinkId")
        }
    }

    // MARK: - Migration

    private static func migrateFromUserDefaults() -> UserPreferences {
        var providerRaw = UserDefaults.standard.string(forKey: "sideline.llm.provider") ?? "openai"
        if providerRaw == "typesafe" { providerRaw = "openai" }

        var modelsByProvider: [String: String] = [:]
        for raw in ["openai", "anthropic", "google", "openrouter"] {
            if let model = UserDefaults.standard.string(forKey: "sideline.llm.model.\(raw)"),
               !model.isEmpty {
                modelsByProvider[raw] = model
            }
        }
        let legacyModel = UserDefaults.standard.string(forKey: "sideline.llm.model")
        let model = (modelsByProvider[providerRaw] ?? legacyModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = (model?.isEmpty == false) ? model! : defaultModel(for: providerRaw)
        if modelsByProvider[providerRaw] == nil {
            modelsByProvider[providerRaw] = resolvedModel
        }

        let guardrailsData = UserDefaults.standard.data(forKey: GuardrailSettings.storageKey)
            ?? ((try? JSONEncoder().encode(GuardrailSettings())) ?? Data())
        let criteriaData = UserDefaults.standard.data(forKey: AgentCriteriaBundle.storageKey)
            ?? ((try? JSONEncoder().encode(AgentCriteriaBundle())) ?? Data())

        return UserPreferences(
            llmProviderRaw: providerRaw,
            llmModel: resolvedModel,
            llmModelsByProviderJSON: encodeModelsByProvider(modelsByProvider),
            guardrailsJSON: guardrailsData,
            agentCriteriaJSON: criteriaData,
            isDarkMode: UserDefaults.standard.bool(forKey: "sideline.appearance.darkMode"),
            liveActivityEnabled: UserDefaults.standard.bool(forKey: LiveActivityManager.enabledKey),
            fantasyProsScoringRaw: UserDefaults.standard.string(forKey: "sideline.fantasypros.scoring")
                ?? FantasyProsScoring.half.rawValue,
            activeLeagueLinkId: UserDefaults.standard.string(forKey: "sideline.activeLeagueLinkId")
        )
    }

    private static func defaultModel(for providerRaw: String) -> String {
        switch providerRaw {
        case "anthropic": return "claude-haiku-4-5-20251001"
        case "google": return "gemini-2.5-flash-lite"
        case "openrouter": return "google/gemini-2.5-flash-lite"
        default: return "gpt-4o-mini"
        }
    }
}
