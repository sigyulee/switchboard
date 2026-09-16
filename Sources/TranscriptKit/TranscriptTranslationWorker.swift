import BridgeCore
import Foundation
@preconcurrency import Translation

@available(macOS 26.0, *)
actor TranscriptTranslationWorker {
    struct Request: Sendable {
        let entry: TranscriptEntry
    }
    private let source: String
    private let target: String
    private let queue: AsyncStream<Request>
    private let continuation: AsyncStream<Request>.Continuation
    private let completion: @Sendable (TranscriptEntry, String?, TranscriptTranslationStatus) async -> Void
    private var session: TranslationSession?
    private var history: [TranscriptEntry]
    private var task: Task<Void, Never>?
    private var closed = false

    init(
        source: String, target: String, initialEntries: [TranscriptEntry] = [],
        completion: @escaping @Sendable (TranscriptEntry, String?, TranscriptTranslationStatus) async -> Void
    ) {
        self.source = source
        self.target = target
        history = Array(
            initialEntries.sorted {
                ($0.startFrame, $0.endFrame, $0.id.uuidString)
                    < ($1.startFrame, $1.endFrame, $1.id.uuidString)
            }.suffix(TranscriptTranslationContextPlan.maximumContextEntries))
        self.completion = completion
        (queue, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(32))
    }

    func start() {
        guard task == nil, !closed else { return }
        task = Task { await self.consume() }
    }

    func enqueue(_ entry: TranscriptEntry) -> Bool {
        guard !closed else { return false }
        switch continuation.yield(Request(entry: entry)) {
        case .enqueued: return true
        default: return false
        }
    }

    func finish() async {
        closed = true
        continuation.finish()
        await task?.value
        task = nil
        session = nil
        history = []
    }

    func cancel() async {
        closed = true
        continuation.finish()
        task?.cancel()
        session?.cancel()
        await task?.value
        task = nil
        session = nil
        history = []
    }

    private func consume() async {
        let availability = LanguageAvailability()
        let source = Locale.Language(identifier: source)
        let target = Locale.Language(identifier: target)
        for await request in queue {
            guard !Task.isCancelled else { break }
            let status = await availability.status(from: source, to: target)
            guard !Task.isCancelled else { break }
            guard status == .installed else {
                await completion(request.entry, nil, status == .supported ? .downloadRequired : .unsupported)
                continue
            }
            if session == nil {
                session = TranscriptContextualTranslator.makeSession(source: source, target: target)
            }
            guard let session else { continue }
            history.removeAll { $0.id == request.entry.id }
            history.append(request.entry)
            history.sort {
                ($0.startFrame, $0.endFrame, $0.id.uuidString)
                    < ($1.startFrame, $1.endFrame, $1.id.uuidString)
            }
            if history.count > TranscriptTranslationContextPlan.maximumContextEntries {
                history.removeFirst(history.count - TranscriptTranslationContextPlan.maximumContextEntries)
            }
            do {
                let plan = try TranscriptTranslationContextPlan(
                    entries: history,
                    revisionCount: min(
                        TranscriptTranslationContextPlan.maximumRevisionEntries, history.count))
                if plan.revisedEntryIDs.contains(request.entry.id),
                    let values = try await TranscriptContextualTranslator.contextualTranslations(
                        plan, session: session)
                {
                    for entry in plan.entries where plan.revisedEntryIDs.contains(entry.id) {
                        guard let value = values[entry.id] else { throw TranscriptFailure.invalidEntry }
                        await completion(entry, value, .translated)
                    }
                    continue
                }
            } catch {
                guard !Task.isCancelled else { break }
                // A contextual result that cannot be mapped back to exact entries is
                // ignored. The current utterance still gets the proven standalone path.
            }
            do {
                let text = try await TranscriptContextualTranslator.standaloneTranslation(
                    request.entry.original, session: session)
                await completion(request.entry, text, .translated)
            } catch {
                guard !Task.isCancelled else { break }
                await completion(request.entry, nil, .failed)
            }
        }
    }
}
