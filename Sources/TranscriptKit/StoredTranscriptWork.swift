import BridgeCore
import CryptoKit
import Darwin
import Foundation
import RecorderKit

public enum StoredTranscriptMode: String, Codable, CaseIterable, Sendable {
    case remaining, fullTranscription, translationOnly
}
public enum StoredTranscriptPhase: String, Codable, Sendable {
    case preparing, transcribing, translating, paused, review, failed
    public var processing: Bool { [.preparing, .transcribing, .translating].contains(self) }
}
public struct StoredTranscriptWorkRecord: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public let itemID: UUID
    public let mode: StoredTranscriptMode
    public let configuration: TranscriptConfiguration
    public var phase: StoredTranscriptPhase
    public var error: String?
    let sourceSignature: String
    let baselineDigest: String
}

/// One durable candidate per package. The app joins the owned processor before moving or publishing it.
public actor StoredTranscriptWork {
    public nonisolated let directory: URL
    public private(set) var record: StoredTranscriptWorkRecord
    private let item: RecordingItem
    private var running = false
    private static let folder = ".transcript-work"

    private init(item: RecordingItem, directory: URL, record: StoredTranscriptWorkRecord) {
        self.item = item
        self.directory = directory
        self.record = record
    }

    public static func create(
        item: RecordingItem, mode: StoredTranscriptMode, configuration: TranscriptConfiguration
    ) async throws -> StoredTranscriptWork {
        try Task.checkCancellation()
        try configuration.validate()
        let fresh = try RecordingLibrary.item(at: item.directory)
        guard fresh.id == item.id, fresh.manifest.createdAt == item.manifest.createdAt else {
            throw TranscriptFailure.staleSession
        }
        let item = fresh
        guard item.manifest.status != .recording, item.manifest.status != .finalizing else {
            throw TranscriptFailure.alreadyRunning
        }
        let destination = item.directory.appendingPathComponent(folder, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw TranscriptFailure.alreadyRunning
        }
        let baseline = try TranscriptJournal.digest(sessionID: item.id, directory: item.directory)
        let current = try TranscriptJournal(sessionID: item.id, directory: item.directory)
        let entries = await current.snapshot()
        let previous = await current.configuration()
        let mode: StoredTranscriptMode =
            mode == .remaining
                && previous.map {
                    $0.callerLocaleIdentifier != configuration.callerLocaleIdentifier
                        || $0.agentLocaleIdentifier != configuration.agentLocaleIdentifier
                } == true ? .fullTranscription : mode
        if mode == .translationOnly && entries.isEmpty { throw TranscriptFailure.invalidEntry }
        let signature = try sourceSignature(item, includeAudio: mode != .translationOnly)
        if mode != .translationOnly { try validateAudio(item) }
        let id = UUID()
        let temporary = item.directory.appendingPathComponent(
            ".transcript-work-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        do {
            let journal = try TranscriptJournal(sessionID: item.id, directory: temporary)
            var seed = mode == .fullTranscription ? [] : entries
            if mode == .translationOnly
                || previous?.targetLocaleIdentifier != configuration.targetLocaleIdentifier
            {
                seed = seed.map {
                    var entry = $0
                    entry.translation = nil
                    entry.translationStatus =
                        configuration.skipsTranslation(for: entry.side) ? .notNeeded : .pending
                    return entry
                }
            }
            let checkpoints = mode == .fullTranscription ? [:] : await current.completedThrough()
            let gaps = mode == .fullTranscription ? [] : await current.gaps()
            try await journal.seed(
                entries: seed, configuration: configuration, checkpoints: checkpoints, gaps: gaps)
            let record = StoredTranscriptWorkRecord(
                version: 1, id: id, itemID: item.id, mode: mode, configuration: configuration,
                phase: .preparing, error: nil, sourceSignature: signature,
                baselineDigest: baseline)
            try save(record, at: temporary)
            try Task.checkCancellation()
            guard try TranscriptJournal.digest(sessionID: item.id, directory: item.directory) == baseline
            else {
                throw TranscriptFailure.staleSession
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            return StoredTranscriptWork(item: item, directory: destination, record: record)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public static func restore(item: RecordingItem) async throws -> StoredTranscriptWork? {
        let directory = item.directory.appendingPathComponent(folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        try requireDirectory(directory)
        let url = directory.appendingPathComponent("job.json")
        try requireRegularFile(url, limit: 16_384)
        var record = try JSONDecoder().decode(StoredTranscriptWorkRecord.self, from: Data(contentsOf: url))
        guard record.version == 1, record.itemID == item.id else { throw TranscriptFailure.staleSession }
        try record.configuration.validate()
        _ = try TranscriptJournal.readArchive(sessionID: item.id, directory: directory)
        if record.phase.processing {
            record.phase = .paused
            try save(record, at: directory)
        }
        return StoredTranscriptWork(item: item, directory: directory, record: record)
    }

    public func snapshot() throws -> [TranscriptEntry] {
        try TranscriptJournal.readArchive(sessionID: item.id, directory: directory).entries
    }

    public func run(
        processor: StoredTranscriptProcessor,
        onPhase: @escaping @Sendable (StoredTranscriptPhase) async -> Void = { _ in },
        onEvent: @escaping @Sendable (TranscriptEvent) async -> Void = { _ in }
    ) async throws -> StoredTranscriptResult {
        guard !running, record.phase != .review else { throw TranscriptFailure.alreadyRunning }
        running = true
        defer { running = false }
        do {
            try Task.checkCancellation()
            try validateOwnership()
            try validateSource()
            if record.mode != .translationOnly { try Self.validateAudio(item) }
            try setPhase(.preparing)
            await onPhase(.preparing)
            let result = try await processor.process(
                item: item, destinationDirectory: directory, mode: record.mode,
                onPhase: { phase in
                    try await self.setPhase(phase)
                    await onPhase(phase)
                }, onEvent: onEvent)
            let phase: StoredTranscriptPhase =
                result.disposition == .paused
                ? .paused : result.progress.hasWork || !result.sourceFailures.isEmpty ? .failed : .review
            let errors = result.sourceFailures.values.sorted() + result.states.values.compactMap(\.message)
            record.error =
                phase == .failed
                ? (errors.isEmpty
                    ? TranscriptFailure.unavailableFormat.localizedDescription
                    : errors.joined(separator: "\n")) : nil
            try setPhase(phase)
            await onPhase(phase)
            return result
        } catch {
            record.error = error is CancellationError ? nil : String(error.localizedDescription.prefix(4096))
            record.phase = error is CancellationError ? .paused : .failed
            try? persist(record)
            throw error
        }
    }

    public func apply() async throws {
        guard !running, record.phase == .review else { throw TranscriptFailure.alreadyRunning }
        running = true
        defer { running = false }
        try Task.checkCancellation()
        try validateOwnership()
        try validateSource()
        let progress = try await StoredTranscriptProcessor.progress(
            item: item, destinationDirectory: directory, mode: record.mode)
        guard !progress.needsConfiguration, !progress.hasWork else { throw TranscriptFailure.invalidEntry }
        try Task.checkCancellation()
        try validateOwnership()
        try validateSource()
        let candidate = try TranscriptJournal.digest(sessionID: item.id, directory: directory)
        if try TranscriptJournal.digest(sessionID: item.id, directory: item.directory) != candidate {
            try TranscriptJournal.publish(
                sessionID: item.id, from: directory, to: item.directory, expectedDigest: record.baselineDigest
            )
        }
        try Self.remove(directory, id: record.id)
    }

    public func discard() throws {
        guard !running else { throw TranscriptFailure.alreadyRunning }
        try Self.remove(directory, id: record.id)
    }

    private func setPhase(_ phase: StoredTranscriptPhase) throws {
        var updated = record
        updated.phase = phase
        try persist(updated)
        record = updated
    }
    private func persist(_ updated: StoredTranscriptWorkRecord) throws {
        try validateOwnership()
        try Self.save(updated, at: directory)
    }
    private func validateOwnership() throws {
        try Self.requireDirectory(directory)
        let url = directory.appendingPathComponent("job.json")
        try Self.requireRegularFile(url, limit: 16_384)
        let current = try JSONDecoder().decode(StoredTranscriptWorkRecord.self, from: Data(contentsOf: url))
        guard current.id == record.id, current.itemID == item.id,
            current.mode == record.mode, current.configuration == record.configuration
        else { throw TranscriptFailure.staleSession }
    }
    private func validateSource() throws {
        let fresh = try RecordingLibrary.item(at: item.directory)
        guard fresh.manifest.status != .recording, fresh.manifest.status != .finalizing else {
            throw TranscriptFailure.alreadyRunning
        }
        guard
            try Self.sourceSignature(fresh, includeAudio: record.mode != .translationOnly)
                == record.sourceSignature
        else { throw TranscriptFailure.staleSession }
    }
    private static func validateAudio(_ item: RecordingItem) throws {
        guard !item.manifest.segments.isEmpty else { throw TranscriptFailure.invalidAudio }
        for side in AudioSide.allCases where item.manifest.segments.contains(where: { $0.side == side }) {
            let reader = try RecordingAudioReader(item: item, side: side)
            for segment in item.manifest.segments where segment.side == side {
                try Task.checkCancellation()
                _ = try reader.read(at: segment.startFrame, frames: 1)
                _ = try reader.read(at: segment.startFrame + segment.frames - 1, frames: 1)
            }
        }
    }
    private static func sourceSignature(_ item: RecordingItem, includeAudio: Bool) throws -> String {
        var manifest = item.manifest
        manifest.title = ""
        manifest.status = .complete
        manifest.failure = nil
        manifest.failureCode = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var bytes = try encoder.encode(manifest)
        if includeAudio {
            for segment in manifest.segments {
                let url = item.directory.appendingPathComponent(segment.filename)
                try requireRegularFile(url, limit: Int.max)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw TranscriptFailure.invalidPath }
                bytes.append(
                    Data(
                        "\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
                            .utf8))
            }
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func save(_ record: StoredTranscriptWorkRecord, at directory: URL) throws {
        try requireDirectory(directory)
        let url = directory.appendingPathComponent("job.json")
        if FileManager.default.fileExists(atPath: url.path) { try requireRegularFile(url, limit: 16_384) }
        let data = try JSONEncoder().encode(record)
        guard data.count <= 16_384 else { throw TranscriptFailure.capacityExceeded }
        try data.write(to: url, options: .atomic)
    }
    private static func remove(_ directory: URL, id: UUID) throws {
        try requireDirectory(directory)
        let url = directory.appendingPathComponent("job.json")
        try requireRegularFile(url, limit: 16_384)
        let current = try JSONDecoder().decode(StoredTranscriptWorkRecord.self, from: Data(contentsOf: url))
        guard current.id == id else { throw TranscriptFailure.staleSession }
        try FileManager.default.removeItem(at: directory)
    }
    private static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw TranscriptFailure.invalidPath
        }
    }
    private static func requireRegularFile(_ url: URL, limit: Int) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
            size >= 0, size <= limit
        else { throw TranscriptFailure.invalidPath }
    }
}
