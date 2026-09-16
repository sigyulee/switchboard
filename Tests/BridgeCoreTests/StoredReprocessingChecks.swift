import AVFoundation
import BridgeCore
import Foundation
import RecorderKit
import TranscriptKit

struct StoredReprocessingChecks {
    func stagesRecordOnlyCoverageAndRestoresPausedWork() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await publish(item)
        let work = try await StoredTranscriptWork.create(
            item: item, mode: .fullTranscription, configuration: config())
        let progress = try await StoredTranscriptProcessor.progress(
            item: item, destinationDirectory: work.directory, mode: .fullTranscription)
        try check(progress.remainingIntervals[.caller] == [try SessionInterval(startFrame: 0, frames: 100)])
        try check(progress.remainingIntervals[.agent] == [try SessionInterval(startFrame: 150, frames: 100)])
        try check(try await work.snapshot().isEmpty)
        let journal = try TranscriptJournal(sessionID: item.id, directory: work.directory)
        let token = await journal.beginGeneration()
        try await journal.prepareCheckpoints(durationFrames: 250, token: token)
        try await journal.commitCompletedThrough(
            [.caller: 50],
            completion: TranscriptCompletion(
                finalizedSources: [.caller],
                states: [.caller: TranscriptSideState(side: .caller, speech: .ready, translation: .notNeeded)]
            ), durationFrames: 250, token: token)
        var rejected = false
        do { try await work.apply() } catch { rejected = true }
        try check(rejected)
        let restored = try await StoredTranscriptWork.restore(item: item)!
        try check(await restored.record.phase == .paused)
        let resumed = try await StoredTranscriptProcessor.progress(
            item: item, destinationDirectory: restored.directory, mode: .fullTranscription)
        try check(resumed.completedThrough[.caller] == 50)
        try check(resumed.remainingIntervals[.caller] == [try SessionInterval(startFrame: 50, frames: 50)])
        try check(try Data(contentsOf: item.directory.appendingPathComponent("transcript.json")) == original)
        try await restored.discard()
        try check(try await StoredTranscriptWork.restore(item: item) == nil)
    }

    func remainingKeepsFinalTextAndLanguageChangeRestartsFullCoverage() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try item.manifest.segments.map {
            try Data(contentsOf: item.directory.appendingPathComponent($0.filename))
        }
        let journal = try TranscriptJournal(sessionID: item.id, directory: item.directory)
        let entry = TranscriptEntry(
            side: .caller, startFrame: 0, endFrame: 50, original: "Already done", isFinal: true)
        try await journal.seed(
            entries: [entry], configuration: config(), checkpoints: [.caller: 50], gaps: [])
        let original = try Data(contentsOf: item.directory.appendingPathComponent("transcript.json"))
        let remaining = try await StoredTranscriptWork.create(
            item: item, mode: .remaining, configuration: config())
        try check(try await remaining.snapshot() == [entry])
        let resumed = try await StoredTranscriptProcessor.progress(
            item: item, destinationDirectory: remaining.directory, mode: .remaining)
        try check(resumed.remainingIntervals[.caller] == [try SessionInterval(startFrame: 50, frames: 50)])
        try check(resumed.remainingIntervals[.agent] == [try SessionInterval(startFrame: 150, frames: 100)])
        try await remaining.discard()
        let changed = try TranscriptConfiguration(
            callerLocaleIdentifier: "en-GB", agentLocaleIdentifier: "en-US", targetLocaleIdentifier: "en-US")
        let restarted = try await StoredTranscriptWork.create(
            item: item, mode: .remaining, configuration: changed)
        try check(await restarted.record.mode == .fullTranscription)
        try check(try await restarted.snapshot().isEmpty)
        let full = try await StoredTranscriptProcessor.progress(
            item: item, destinationDirectory: restarted.directory, mode: .fullTranscription)
        try check(full.remainingIntervals[.caller] == [try SessionInterval(startFrame: 0, frames: 100)])
        try check(full.remainingIntervals[.agent] == [try SessionInterval(startFrame: 150, frames: 100)])
        try check(try Data(contentsOf: item.directory.appendingPathComponent("transcript.json")) == original)
        try check(
            try item.manifest.segments.map {
                try Data(contentsOf: item.directory.appendingPathComponent($0.filename))
            } == audio)
        try await restarted.discard()
    }

    func translationReviewsBeforeApplyAndPreservesTiming() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await publish(item)
        let saved = try TranscriptJournal.readArchive(sessionID: item.id, directory: item.directory)
        let gap = TranscriptGap(
            side: .caller, startFrame: 25, endFrame: 30, reason: "historical delivery gap")
        let source = try TranscriptJournal(sessionID: item.id, directory: item.directory)
        try await source.seed(
            entries: saved.entries, configuration: saved.configuration!,
            checkpoints: [.caller: 100, .agent: 250], gaps: [gap])
        let original = try Data(contentsOf: item.directory.appendingPathComponent("transcript.json"))
        let before = try TranscriptJournal.readArchive(sessionID: item.id, directory: item.directory)
        let work = try await StoredTranscriptWork.create(
            item: item, mode: .translationOnly, configuration: config())
        _ = try await work.run(processor: StoredTranscriptProcessor())
        try check(await work.record.phase == .review)
        let entries = try await work.snapshot()
        try check(entries.map(\.id) == before.entries.map(\.id))
        try check(entries.map(\.original) == ["Saved caller", "Saved Agent"])
        try check(entries.map(\.startFrame) == [0, 150])
        try check(entries.map(\.endFrame) == [100, 250])
        try check(entries.allSatisfy { $0.translation == nil && $0.translationStatus == .notNeeded })
        try check(try Data(contentsOf: item.directory.appendingPathComponent("transcript.json")) == original)
        let candidateProgress = try await StoredTranscriptProcessor.progress(
            item: item, destinationDirectory: work.directory, mode: .translationOnly)
        try check(candidateProgress.completedThrough == [.caller: 100, .agent: 250])
        let candidateArchive = try TranscriptJournal.readArchive(
            sessionID: item.id, directory: work.directory)
        try check(candidateArchive.gaps == [gap])
        let restored = try await StoredTranscriptWork.restore(item: item)!
        try check(await restored.record.phase == .review)
        try await restored.apply()
        try check(
            try TranscriptJournal.readArchive(sessionID: item.id, directory: item.directory).entries
                == entries)
        try check(try await StoredTranscriptWork.restore(item: item) == nil)
        try check(try RecordingLibrary.item(at: item.directory).manifest == item.manifest)
    }

    func refusesChangedPublicationAndKeepsCandidate() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await publish(item)
        let work = try await StoredTranscriptWork.create(
            item: item, mode: .translationOnly, configuration: config())
        _ = try await work.run(processor: StoredTranscriptProcessor())
        let changed = try await publish(item, caller: "Changed elsewhere")
        var rejected = false
        do { try await work.apply() } catch { rejected = true }
        try check(rejected)
        try check(await work.record.phase == .review)
        try check(try Data(contentsOf: item.directory.appendingPathComponent("transcript.json")) == changed)
        try await work.discard()
        try check(try Data(contentsOf: item.directory.appendingPathComponent("transcript.json")) == changed)
    }

    func missingAudioPreservesTextAndTranslationNeedsNoPCM() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await publish(item)
        try FileManager.default.removeItem(at: item.directory.appendingPathComponent("caller.caf"))
        var rejected = false
        do {
            _ = try await StoredTranscriptWork.create(
                item: item, mode: .fullTranscription, configuration: config())
        } catch { rejected = true }
        try check(rejected)
        try check(
            !FileManager.default.fileExists(
                atPath: item.directory.appendingPathComponent(".transcript-work").path))
        try check(try Data(contentsOf: item.directory.appendingPathComponent("transcript.json")) == original)
        let work = try await StoredTranscriptWork.create(
            item: item, mode: .translationOnly, configuration: config())
        _ = try await work.run(processor: StoredTranscriptProcessor())
        try check(await work.record.phase == .review)
    }

    func publishedCandidateCanFinishCleanupAfterRestart() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await publish(item)
        let work = try await StoredTranscriptWork.create(
            item: item, mode: .translationOnly, configuration: config())
        _ = try await work.run(processor: StoredTranscriptProcessor())
        let baseline = try TranscriptJournal.digest(sessionID: item.id, directory: item.directory)
        try TranscriptJournal.publish(
            sessionID: item.id, from: work.directory, to: item.directory, expectedDigest: baseline)
        let restored = try await StoredTranscriptWork.restore(item: item)!
        try await restored.apply()
        try check(try await StoredTranscriptWork.restore(item: item) == nil)
    }

    func replacedCandidateCannotBeAppliedByThePreviousJob() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await publish(item)
        let previous = try await StoredTranscriptWork.create(
            item: item, mode: .translationOnly, configuration: config())
        _ = try await previous.run(processor: StoredTranscriptProcessor())
        try await previous.discard()
        let replacement = try await StoredTranscriptWork.create(
            item: item, mode: .translationOnly, configuration: config())
        _ = try await replacement.run(processor: StoredTranscriptProcessor())
        var rejected = false
        do { try await previous.apply() } catch { rejected = true }
        try check(rejected)
        let restored = try await StoredTranscriptWork.restore(item: item)!
        let replacementID = await replacement.record.id
        try check(await restored.record.id == replacementID)
        try check(try Data(contentsOf: item.directory.appendingPathComponent("transcript.json")) == original)
        try await restored.discard()
    }

    func cancelledJobDoesNotBecomeReviewReady() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await publish(item)
        let work = try await StoredTranscriptWork.create(
            item: item, mode: .translationOnly, configuration: config())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await work.run(processor: StoredTranscriptProcessor())
        }
        var cancelled = false
        do { _ = try await task.value } catch is CancellationError { cancelled = true }
        try check(cancelled)
        try check(await work.record.phase == .paused)
    }

    func unavailableEngineLeavesFailedCandidateAndCurrentTextIntact() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await publish(item)
        let configuration = try TranscriptConfiguration(
            callerLocaleIdentifier: "zz-ZZ", agentLocaleIdentifier: "zz-ZZ", targetLocaleIdentifier: "en-US")
        let work = try await StoredTranscriptWork.create(
            item: item, mode: .fullTranscription, configuration: configuration)
        _ = try await work.run(processor: StoredTranscriptProcessor())
        try check(await work.record.phase == .failed)
        var rejected = false
        do { try await work.apply() } catch { rejected = true }
        try check(rejected)
        try check(try Data(contentsOf: item.directory.appendingPathComponent("transcript.json")) == original)
        let restored = try await StoredTranscriptWork.restore(item: item)!
        try check(await restored.record.phase == .failed)
    }

    func copiedPackageRestoresPendingReviewWithoutReprocessingAudio() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await publish(item)
        let work = try await StoredTranscriptWork.create(
            item: item, mode: .fullTranscription, configuration: config())
        let journal = try TranscriptJournal(sessionID: item.id, directory: work.directory)
        let token = await journal.beginGeneration()
        try await journal.prepareCheckpoints(durationFrames: 250, token: token)
        let completion = TranscriptCompletion(
            finalizedSources: Set(AudioSide.allCases),
            states: Dictionary(
                uniqueKeysWithValues: AudioSide.allCases.map {
                    ($0, TranscriptSideState(side: $0, speech: .ready, translation: .notNeeded))
                }))
        try await journal.commitCompletedThrough(
            [.caller: 100, .agent: 250], completion: completion, durationFrames: 250, token: token)
        _ = try await work.run(processor: StoredTranscriptProcessor())
        try check(await work.record.phase == .review)
        let copy = root.appendingPathComponent("Copied.switchboard")
        try FileManager.default.copyItem(at: item.directory, to: copy)
        let restored = try await StoredTranscriptWork.restore(item: RecordingLibrary.item(at: copy))!
        try await restored.apply()
        try check(try await StoredTranscriptWork.restore(item: RecordingLibrary.item(at: copy)) == nil)
        try check(try await StoredTranscriptWork.restore(item: item) != nil)
    }

    func unfinishedRecordingCannotStartReprocessing() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await publish(item)
        var manifest = item.manifest
        manifest.status = .recording
        try manifest.save(to: item.directory)
        var rejected = false
        do {
            _ = try await StoredTranscriptWork.create(
                item: item, mode: .fullTranscription, configuration: config())
        } catch { rejected = true }
        try check(rejected)
        try check(try Data(contentsOf: item.directory.appendingPathComponent("transcript.json")) == original)
    }

    func reprocessingCannotUseThePublishedJournalAsItsDestination() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await publish(item)
        var rejected = false
        do {
            _ = try await StoredTranscriptProcessor().process(
                item: item, destinationDirectory: item.directory, mode: .fullTranscription)
        } catch { rejected = true }
        try check(rejected)
        try check(try Data(contentsOf: item.directory.appendingPathComponent("transcript.json")) == original)
    }

    func replacedSelectionCannotCreateWorkForAnotherRecording() async throws {
        let (root, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var state = try SessionState(name: "Replacement")
        try state.start(at: 0)
        try state.end(at: 250)
        let replacement = try SessionManifest(state: state, isDraft: false)
        var manifest = item.manifest
        manifest.id = replacement.id
        manifest.createdAt = replacement.createdAt
        manifest.title = replacement.title
        try manifest.save(to: item.directory)
        try JSONEncoder().encode(replacement).write(
            to: item.directory.appendingPathComponent(SessionManifest.filename))
        var rejected = false
        do {
            _ = try await StoredTranscriptWork.create(
                item: item, mode: .fullTranscription, configuration: config())
        } catch { rejected = true }
        try check(rejected)
        try check(
            !FileManager.default.fileExists(
                atPath: item.directory.appendingPathComponent(".transcript-work").path))
    }

    private func check(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        try expect(value, file: file, line: line)
    }
    private func config() throws -> TranscriptConfiguration {
        try TranscriptConfiguration(
            callerLocaleIdentifier: "en-US", agentLocaleIdentifier: "en-US", targetLocaleIdentifier: "en-US")
    }
    private func fixture() throws -> (URL, RecordingItem) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("Saved.switchboard")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var state = try SessionState(name: "Record Only")
        try state.start(at: 0)
        try state.end(at: 250)
        let session = try SessionManifest(state: state, isDraft: false)
        var manifest = RecordingManifest(
            id: session.id, title: session.title, createdAt: session.createdAt, owner: .manual)
        manifest.durationFrames = 250
        manifest.status = .complete
        manifest.segments = [
            RecordingSegment(side: .caller, filename: "caller.caf", startFrame: 0, frames: 100),
            RecordingSegment(side: .agent, filename: "agent.caf", startFrame: 150, frames: 100),
        ]
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        for segment in manifest.segments {
            let file = try AVAudioFile(
                forWriting: directory.appendingPathComponent(segment.filename), settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
            buffer.frameLength = 100
            for channel in 0..<2 {
                buffer.floatChannelData![channel].initialize(repeating: 0.125, count: 100)
            }
            try file.write(from: buffer)
        }
        try manifest.save(to: directory)
        try JSONEncoder().encode(session).write(
            to: directory.appendingPathComponent(SessionManifest.filename))
        return (root, RecordingItem(directory: directory, manifest: manifest))
    }
    @discardableResult private func publish(_ item: RecordingItem, caller: String = "Saved caller")
        async throws -> Data
    {
        let journal = try TranscriptJournal(sessionID: item.id, directory: item.directory)
        try await journal.setConfiguration(
            TranscriptConfiguration(
                callerLocaleIdentifier: "en-US", agentLocaleIdentifier: "en-US",
                targetLocaleIdentifier: "ko-KR"))
        let token = await journal.beginGeneration()
        for (side, start, text) in [
            (AudioSide.caller, Int64(0), caller), (.agent, Int64(150), "Saved Agent"),
        ] {
            var entry = TranscriptEntry(
                side: side, startFrame: start, endFrame: start + 100, original: text, isFinal: true)
            entry.translation = "이전 번역"
            entry.translationStatus = .translated
            try await journal.upsert(entry, token: token)
        }
        return try Data(contentsOf: item.directory.appendingPathComponent("transcript.json"))
    }
}
