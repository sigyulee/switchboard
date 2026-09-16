import BridgeCore
import Foundation
import Observation
import RecorderKit
import TranscriptKit

@MainActor @Observable final class StoredProcessingController {
    private let processor = StoredTranscriptProcessor()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var works: [UUID: StoredTranscriptWork] = [:]
    private var locations: [UUID: URL] = [:]
    private var records: [UUID: StoredTranscriptWorkRecord] = [:]
    private var candidates: [UUID: [TranscriptEntry]] = [:]
    private var issues: [UUID: String] = [:]
    private var requests: [UUID: (StoredTranscriptMode, TranscriptConfiguration?)] = [:]
    private var activeDirectory: URL?
    private(set) var itemID: UUID?
    private(set) var busy = false
    private(set) var entries: [TranscriptEntry] = []
    private(set) var revision = 0
    var requiredModels: TranscriptConfiguration?

    func record(for item: RecordingItem) -> StoredTranscriptWorkRecord? {
        locations[item.id] == item.directory ? records[item.id] : nil
    }
    func candidateEntries(for item: RecordingItem) -> [TranscriptEntry] {
        locations[item.id] == item.directory ? candidates[item.id, default: []] : []
    }
    func issue(for item: RecordingItem) -> String? {
        locations[item.id] == item.directory ? issue(for: item.id) : nil
    }
    func isWriting(_ item: RecordingItem) -> Bool { isWriting(item.id) && activeDirectory == item.directory }
    func record(for id: UUID) -> StoredTranscriptWorkRecord? { records[id] }
    func candidateEntries(for id: UUID) -> [TranscriptEntry] { candidates[id, default: []] }
    func issue(for id: UUID) -> String? { issues[id] ?? records[id]?.error }
    func isWriting(_ id: UUID) -> Bool { busy && itemID == id }

    func restore(_ item: RecordingItem) async {
        if works[item.id] != nil && locations[item.id] != item.directory && !isWriting(item.id) {
            works[item.id] = nil
            records[item.id] = nil
            candidates[item.id] = nil
            issues[item.id] = nil
        }
        guard works[item.id] == nil else { return }
        if locations[item.id] != item.directory { issues[item.id] = nil }
        locations[item.id] = item.directory
        do {
            guard let work = try await StoredTranscriptWork.restore(item: item), works[item.id] == nil else {
                return
            }
            works[item.id] = work
            locations[item.id] = item.directory
            records[item.id] = await work.record
            candidates[item.id] = try await work.snapshot()
        } catch { issues[item.id] = error.localizedDescription }
    }

    func start(
        _ item: RecordingItem, mode: StoredTranscriptMode = .remaining,
        configuration: TranscriptConfiguration? = nil
    ) {
        guard !busy else { return }
        if works[item.id] != nil && locations[item.id] != item.directory {
            works[item.id] = nil
            records[item.id] = nil
            candidates[item.id] = nil
            issues[item.id] = nil
        }
        busy = true
        activeDirectory = item.directory
        locations[item.id] = item.directory
        itemID = item.id
        let previousRequest = requests[item.id]
        let mode = configuration == nil ? previousRequest?.0 ?? mode : mode
        let configuration = configuration ?? previousRequest?.1
        requests[item.id] = (mode, configuration)
        issues[item.id] = nil
        requiredModels = nil
        let id = UUID()
        generation = id
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == id {
                    busy = false
                    task = nil
                    revision += 1
                }
            }
            do {
                await restore(item)
                try Task.checkCancellation()
                let work: StoredTranscriptWork
                if let existing = works[item.id] {
                    work = existing
                } else {
                    let config: TranscriptConfiguration
                    if let configuration {
                        config = configuration
                    } else {
                        guard
                            let saved = try await StoredTranscriptProcessor.progress(item: item).configuration
                        else { throw TranscriptFailure.invalidConfiguration }
                        config = saved
                    }
                    work = try await StoredTranscriptWork.create(
                        item: item, mode: mode, configuration: config)
                    works[item.id] = work
                    locations[item.id] = item.directory
                }
                try Task.checkCancellation()
                records[item.id] = await work.record
                candidates[item.id] = try await work.snapshot()
                entries = candidates[item.id, default: []]
                _ = try await work.run(
                    processor: processor,
                    onPhase: { [weak self] phase in
                        await self?.receivePhase(phase, itemID: item.id, generation: id)
                    },
                    onEvent: { [weak self] event in
                        await self?.receive(event, itemID: item.id, generation: id)
                    })
                guard generation == id else { return }
                records[item.id] = await work.record
                candidates[item.id] = try await work.snapshot()
                entries = candidates[item.id, default: []]

            } catch {
                if error is CancellationError, works[item.id] != nil {
                    works[item.id] = nil
                    await restore(item)
                }
                if let work = works[item.id] {
                    records[item.id] = await work.record
                    candidates[item.id] = (try? await work.snapshot()) ?? candidates[item.id, default: []]
                }
                if !(error is CancellationError) { issues[item.id] = error.localizedDescription }
            }
        }
    }

    func apply(_ item: RecordingItem) { finish(item, apply: true) }
    func discard(_ item: RecordingItem) { finish(item, apply: false) }

    private func finish(_ item: RecordingItem, apply: Bool) {
        guard !busy, locations[item.id] == item.directory, let work = works[item.id] else { return }
        busy = true
        activeDirectory = item.directory
        itemID = item.id
        task = Task {
            defer {
                busy = false
                task = nil
                revision += 1
            }
            do {
                if apply { try await work.apply() } else { try await work.discard() }
                works[item.id] = nil
                locations[item.id] = nil
                records[item.id] = nil
                candidates[item.id] = nil
                issues[item.id] = nil
                requests[item.id] = nil
                entries = []
            } catch { issues[item.id] = error.localizedDescription }
        }
    }

    func pause() async {
        let pending = task
        pending?.cancel()
        await processor.pause()
        await pending?.value
    }

    private func receivePhase(_ phase: StoredTranscriptPhase, itemID: UUID, generation: UUID) {
        guard self.generation == generation else { return }
        records[itemID]?.phase = phase
    }
    private func receive(_ event: TranscriptEvent, itemID: UUID, generation: UUID) {
        guard self.generation == generation else { return }
        switch event {
        case .partial(let entry), .final(let entry), .upsert(let entry):
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
            candidates[itemID] = entries
        case .state, .gap: break
        }
    }
}

extension StoredTranscriptPhase {
    var label: TextKey {
        switch self {
        case .preparing: .reprocessingPreparing
        case .transcribing: .reprocessingTranscribing
        case .translating: .reprocessingTranslating
        case .paused: .reprocessingPaused
        case .review: .reprocessingReview
        case .failed: .reprocessingFailed
        }
    }
}
