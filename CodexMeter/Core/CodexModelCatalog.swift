import Foundation

/// Which reasoning effort a model advertises through `model/list`.
struct CodexModelSummary: Equatable, Sendable, Identifiable {
    /// The slug accepted by the App Server's `model` parameter.
    let id: String
    let displayName: String
    let supportedReasoningEfforts: [String]
    let defaultReasoningEffort: String?
    let isDefault: Bool
    let isHidden: Bool

    func supports(reasoningEffort: String) -> Bool {
        supportedReasoningEfforts.contains(reasoningEffort)
    }
}

/// Decodes `model/list` pages. The catalog is display and validation data only:
/// a failed lookup must never affect quota display.
enum CodexModelCatalogParser {
    static let maximumPages = 10

    struct Page: Equatable, Sendable {
        let models: [CodexModelSummary]
        let nextCursor: String?
    }

    static func page(fromResult result: [String: Any]) -> Page {
        let rows = result["data"] as? [[String: Any]] ?? []
        let models = rows.compactMap { row -> CodexModelSummary? in
            // `model` is the slug the send path must use; `id` is a catalog key.
            let slug = (row["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (row["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let slug else { return nil }

            let effortObjects = row["supportedReasoningEfforts"] as? [[String: Any]] ?? []
            let efforts = effortObjects.compactMap { object -> String? in
                guard let effort = object["reasoningEffort"] as? String,
                      !effort.isEmpty else { return nil }
                return effort
            }

            let displayName = (row["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? slug

            return CodexModelSummary(
                id: slug,
                displayName: displayName,
                supportedReasoningEfforts: efforts,
                defaultReasoningEffort: row["defaultReasoningEffort"] as? String,
                isDefault: row["isDefault"] as? Bool ?? false,
                isHidden: row["hidden"] as? Bool ?? false
            )
        }

        let cursor = (result["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Page(models: models, nextCursor: cursor)
    }

    /// Merges pages while keeping the first occurrence of each slug.
    static func merged(_ pages: [Page]) -> [CodexModelSummary] {
        var seen: Set<String> = []
        var models: [CodexModelSummary] = []
        for page in pages {
            for model in page.models where seen.insert(model.id).inserted {
                models.append(model)
            }
        }
        return models
    }
}

/// Chooses a reasoning effort for the window-start prompt.
///
/// The reference implementation let the user pick a model and used its own
/// stored effort. A ping only needs the cheapest supported setting, so the
/// preference order is explicit and never silently substitutes a missing value.
enum UsageWindowReasoningPreference {
    /// Ordered from cheapest to most expensive, matching the values the App
    /// Server advertises.
    static let orderedEfforts = ["minimal", "low", "medium", "high", "xhigh"]

    static func preferred(from supported: [String]) -> String? {
        orderedEfforts.first(where: supported.contains)
    }

    /// Resolves a stored selection, keeping it only while the model still
    /// advertises it. Returns nil instead of switching to another effort.
    static func resolved(stored: String?, model: CodexModelSummary) -> String? {
        if let stored, model.supports(reasoningEffort: stored) {
            return stored
        }
        return nil
    }

    /// The suggestion offered when a model is first selected.
    static func suggested(for model: CodexModelSummary) -> String? {
        preferred(from: model.supportedReasoningEfforts)
            ?? model.defaultReasoningEffort
            ?? model.supportedReasoningEfforts.first
    }
}
