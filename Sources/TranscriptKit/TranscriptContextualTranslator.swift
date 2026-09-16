import BridgeCore
import Foundation
@preconcurrency import Translation

@available(macOS 26.0, *)
enum TranscriptContextualTranslator {
    static func makeSession(
        source: Locale.Language, target: Locale.Language
    ) -> TranslationSession {
        #if compiler(>=6.3)
            if #available(macOS 26.4, *) {
                return TranslationSession(
                    installedSource: source, target: target, preferredStrategy: .highFidelity)
            }
        #endif
        return TranslationSession(installedSource: source, target: target)
    }

    static func contextualTranslations(
        _ plan: TranscriptTranslationContextPlan, session: TranslationSession
    ) async throws -> [UUID: String]? {
        #if compiler(>=6.3)
            guard plan.entries.count > 1 else { return nil }
            guard #available(macOS 26.4, *) else { return nil }
            let response = try await session.translate(plan.attributedSourceText())
            try Task.checkCancellation()
            guard let attributed = response.attributedTargetText else {
                throw TranscriptFailure.invalidEntry
            }
            return try plan.parse(attributed)
        #else
            return nil
        #endif
    }

    static func standaloneTranslation(
        _ text: String, session: TranslationSession
    ) async throws -> String {
        let response = try await session.translate(text)
        try Task.checkCancellation()
        let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty, translated.utf8.count <= TranscriptLimits.maximumTextBytes else {
            throw TranscriptFailure.invalidEntry
        }
        return translated
    }
}
