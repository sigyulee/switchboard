import BridgeCore
import Foundation
@preconcurrency import Translation

public struct TranscriptTranslationContextPlan: Sendable {
    public static let maximumContextEntries = 6
    public static let maximumRevisionEntries = 3
    public static let maximumContextBytes = 8_192

    public let entries: [TranscriptEntry]
    public let revisedEntryIDs: [UUID]
    public let entryLinks: [URL]
    public let sourceText: String

    public init(entries: [TranscriptEntry], revisionCount: Int = maximumRevisionEntries) throws {
        guard !entries.isEmpty, entries.count <= Self.maximumContextEntries,
            (1...min(Self.maximumRevisionEntries, entries.count)).contains(revisionCount),
            Set(entries.map(\.id)).count == entries.count
        else { throw TranscriptFailure.invalidEntry }
        for entry in entries {
            try entry.validate()
            guard entry.isFinal else { throw TranscriptFailure.invalidEntry }
        }
        let sorted = entries.sorted {
            ($0.startFrame, $0.endFrame, $0.id.uuidString)
                < ($1.startFrame, $1.endFrame, $1.id.uuidString)
        }
        let links = try sorted.map { entry in
            guard
                let link = URL(
                    string: "switchboard-entry://\(entry.id.uuidString.lowercased())")
            else { throw TranscriptFailure.invalidEntry }
            return link
        }
        let sourceText = sorted.map(\.original).joined(separator: " ")
        guard sourceText.utf8.count <= Self.maximumContextBytes else {
            throw TranscriptFailure.capacityExceeded
        }
        self.entries = sorted
        revisedEntryIDs = sorted.suffix(revisionCount).map(\.id)
        entryLinks = links
        self.sourceText = sourceText
    }

    @available(macOS 26.4, *)
    public func attributedSourceText() -> AttributedString {
        var result = AttributedString()
        for (index, entry) in entries.enumerated() {
            if index > 0 { result.append(AttributedString(" ")) }
            var value = AttributedString(entry.original)
            value.link = entryLinks[index]
            result.append(value)
        }
        return result
    }

    @available(macOS 26.4, *)
    public func parse(_ translatedText: AttributedString) throws -> [UUID: String] {
        let linkIndices = Dictionary(
            uniqueKeysWithValues: entryLinks.enumerated().map { ($0.element, $0.offset) })
        var fragments = Array(repeating: [String](), count: entries.count)
        var latestIndex = -1
        for run in translatedText.runs {
            let text = String(translatedText.characters[run.range])
            guard let link = run.link else {
                guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TranscriptFailure.invalidEntry
                }
                continue
            }
            guard let index = linkIndices[link], index >= latestIndex,
                index == latestIndex || index == latestIndex + 1
            else { throw TranscriptFailure.invalidEntry }
            fragments[index].append(text)
            latestIndex = index
        }
        guard latestIndex == entries.count - 1 else { throw TranscriptFailure.invalidEntry }

        var result: [UUID: String] = [:]
        for index in entries.indices {
            let value = fragments[index].joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= TranscriptLimits.maximumTextBytes else {
                throw TranscriptFailure.invalidEntry
            }
            result[entries[index].id] = value
        }
        guard result.count == entries.count else { throw TranscriptFailure.invalidEntry }
        return result
    }
}
