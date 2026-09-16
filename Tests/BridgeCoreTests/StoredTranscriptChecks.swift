import BridgeCore
import Foundation
import RecorderKit
import TranscriptKit
@preconcurrency import Translation

struct StoredTranscriptChecks {
    func contextualTranslationKeepsTimelineAndRevisesOnlyRecentEntries() throws {
        guard #available(macOS 26.4, *) else { return }
        let values = (0..<8).map { index in
            TranscriptEntry(
                id: UUID(), side: index.isMultiple(of: 2) ? .caller : .agent,
                startFrame: Int64(index * 100), endFrame: Int64(index * 100 + 80),
                original: "Utterance \(index)", isFinal: true)
        }
        let plan = try TranscriptTranslationContextPlan(
            entries: Array(values.suffix(6)), revisionCount: 3)
        try check(plan.entries.map(\.id) == Array(values.suffix(6)).map(\.id))
        try check(plan.revisedEntryIDs == Array(values.suffix(3)).map(\.id))

        let translated = plan.entries.map { "KO \($0.original)" }
        var output = AttributedString()
        for index in plan.entries.indices {
            if index > 0 { output.append(AttributedString(" ")) }
            var value = AttributedString(translated[index])
            value.link = plan.entryLinks[index]
            output.append(value)
        }
        let parsed = try plan.parse(output)
        try check(plan.revisedEntryIDs.compactMap { parsed[$0] } == Array(translated.suffix(3)))
        try check(plan.entries.map(\.startFrame) == Array(values.suffix(6)).map(\.startFrame))
    }

    func contextualTranslationRejectsAmbiguousEngineOutput() throws {
        guard #available(macOS 26.4, *) else { return }
        let values = (0..<2).map { index in
            TranscriptEntry(
                id: UUID(), side: .caller, startFrame: Int64(index * 100),
                endFrame: Int64(index * 100 + 80), original: "Line \(index)", isFinal: true)
        }
        let plan = try TranscriptTranslationContextPlan(entries: values, revisionCount: 2)
        var duplicate = AttributedString("첫 번째")
        duplicate.link = plan.entryLinks[0]
        var duplicateMiddle = AttributedString("두 번째")
        duplicateMiddle.link = plan.entryLinks[1]
        duplicate.append(duplicateMiddle)
        var duplicateTail = AttributedString("중복")
        duplicateTail.link = plan.entryLinks[0]
        duplicate.append(duplicateTail)
        var reversed = AttributedString("두 번째")
        reversed.link = plan.entryLinks[1]
        var first = AttributedString("첫 번째")
        first.link = plan.entryLinks[0]
        reversed.append(first)
        var missing = AttributedString("첫 번째")
        missing.link = plan.entryLinks[0]
        var unknown = AttributedString("알 수 없음")
        unknown.link = URL(string: "switchboard-entry://unknown")!
        for output in [AttributedString("번역만 있고 범위 없음"), duplicate, reversed, missing, unknown] {
            var rejected = false
            do { _ = try plan.parse(output) } catch { rejected = true }
            try check(rejected)
        }
    }

    func contextualTranslationUsesOnlyPriorEntriesFromTheSameSourceLanguage() throws {
        let callerBefore = TranscriptEntry(
            id: UUID(), side: .caller, startFrame: 0, endFrame: 80,
            original: "Caller before", isFinal: true)
        let agentBetween = TranscriptEntry(
            id: UUID(), side: .agent, startFrame: 100, endFrame: 180,
            original: "Agent between", isFinal: true)
        let callerCurrent = TranscriptEntry(
            id: UUID(), side: .caller, startFrame: 200, endFrame: 280,
            original: "Caller current", isFinal: true)
        let callerAfter = TranscriptEntry(
            id: UUID(), side: .caller, startFrame: 300, endFrame: 380,
            original: "Caller after", isFinal: true)
        let mixed = try TranscriptConfiguration(
            callerLocaleIdentifier: "en-US", agentLocaleIdentifier: "ko-KR",
            targetLocaleIdentifier: "ja-JP")
        let mixedContext = try StoredTranscriptProcessor.translationContext(
            for: callerCurrent,
            in: [callerAfter, agentBetween, callerCurrent, callerBefore],
            configuration: mixed)
        try check(mixedContext.map(\.id) == [callerBefore.id, callerCurrent.id])

        let shared = try TranscriptConfiguration(
            callerLocaleIdentifier: "en-US", agentLocaleIdentifier: "en-GB",
            targetLocaleIdentifier: "ko-KR")
        let sharedContext = try StoredTranscriptProcessor.translationContext(
            for: callerCurrent,
            in: [callerAfter, agentBetween, callerCurrent, callerBefore],
            configuration: shared)
        try check(sharedContext.map(\.id) == [callerBefore.id, agentBetween.id, callerCurrent.id])
    }

    func contextualTranslationCarriesInvisibleEntryRanges() throws {
        guard #available(macOS 26.4, *) else { return }
        let entries = (0..<2).map { index in
            TranscriptEntry(
                id: UUID(), side: .caller, startFrame: Int64(index * 100),
                endFrame: Int64(index * 100 + 80), original: "Line \(index)", isFinal: true)
        }
        let plan = try TranscriptTranslationContextPlan(entries: entries, revisionCount: 2)
        let attributed = plan.attributedSourceText()
        try check(String(attributed.characters) == entries.map(\.original).joined(separator: " "))
        for index in entries.indices {
            guard let range = attributed.range(of: entries[index].original) else {
                throw CheckFailure(description: "missing attributed entry")
            }
            try check(attributed[range].runs.allSatisfy { $0.link == plan.entryLinks[index] })
        }
        try check(
            attributed.runs.contains {
                $0.link == nil && String(attributed.characters[$0.range]) == " "
            })
    }

    func recordedEligibilityIncludesInitialBackfillAndSkipsExplicitOff() throws {
        var session = try SessionState(name: "Eligible intervals")
        try session.start(at: 0)
        try session.setTranscription(true, at: 10)
        try session.setTranscription(false, at: 20)
        try session.setTranscription(true, at: 30)
        try session.setTranscription(false, at: 40)
        try session.end(at: 50)
        let metadata = try SessionManifest(state: session, isDraft: false)
        let audio = recording(session: metadata)
        let intervals = try StoredTranscriptProcessor.eligibleIntervals(
            manifest: audio, session: metadata, completedThrough: [:], finalEntries: [])
        try check(intervals[.caller] == [interval(0, 20), interval(30, 10)])
        try check(intervals[.agent] == [interval(5, 15)])
        let clipped = try StoredTranscriptProcessor.eligibleIntervals(
            manifest: audio, session: metadata, completedThrough: [.caller: 15],
            finalEntries: [entry(side: .caller, start: 17, end: 19)])
        try check(clipped[.caller] == [interval(15, 2), interval(19, 1), interval(30, 10)])
    }

    func sessionWithoutEligibleTextIsNoWorkAndLegacyUsesOnlyStoredSegments() async throws {
        var state = try SessionState(name: "No enabled intervals")
        try state.start(at: 0)
        try state.end(at: 50)
        let session = try SessionManifest(state: state, isDraft: false)
        let audio = recording(session: session)
        let none = try StoredTranscriptProcessor.eligibleIntervals(
            manifest: audio, session: session, completedThrough: [:], finalEntries: [])
        try check(none.values.allSatisfy(\.isEmpty))
        let legacy = try StoredTranscriptProcessor.eligibleIntervals(
            manifest: audio, session: nil, completedThrough: [:], finalEntries: [])
        try check(legacy[.caller] == [interval(0, 50)])
        try check(legacy[.agent] == [interval(5, 20)])
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Metadata remains authoritative even if a user renames the extension.
        for name in ["Renamed.mihrecording", "Uppercase.SWITCHBOARD"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try audio.save(to: directory)
            try JSONEncoder().encode(session).write(
                to: directory.appendingPathComponent(SessionManifest.filename))
            let progress = try await StoredTranscriptProcessor.progress(
                item: RecordingItem(directory: directory, manifest: audio))
            try check(progress.remainingIntervals.values.allSatisfy(\.isEmpty))
        }
    }

    func oldJournalFallbackBecomesExplicitBeforeNewWork() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let journal = try TranscriptJournal(sessionID: id, directory: root)
        let token = await journal.beginGeneration()
        try check(await journal.upsert(entry(side: .caller, start: 0, end: 20), token: token))
        let old = try TranscriptJournal(sessionID: id, directory: root)
        try check(await old.completedThrough()[.caller] == 20)
        let generation = await old.beginGeneration()
        try check(await old.prepareCheckpoints(durationFrames: 100, token: generation))
        try check(await old.upsert(entry(side: .caller, start: 30, end: 40), token: generation))
        let reopened = try TranscriptJournal(sessionID: id, directory: root)
        try check(await reopened.completedThrough()[.caller] == 20)
        try check(await reopened.completedThrough()[.agent] == 0)
    }

    func failedDrainNeverAdvancesThatSourcesCheckpoint() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let journal = try TranscriptJournal(sessionID: id, directory: root)
        let token = await journal.beginGeneration()
        try check(await journal.prepareCheckpoints(durationFrames: 100, token: token))
        let receipt = TranscriptCompletion(
            finalizedSources: Set(AudioSide.allCases),
            states: [
                .caller: TranscriptSideState(side: .caller, speech: .ready, translation: .notNeeded),
                .agent: TranscriptSideState(side: .agent, speech: .failed, translation: .ready),
            ])
        try check(receipt.drainedSources == [.caller])
        try check(receipt.states[.agent]?.speech == .failed)
        try check(receipt.states[.caller]?.speech == .stopped)
        try check(
            await journal.commitCompletedThrough(
                [.caller: 90, .agent: 90], completion: receipt, durationFrames: 100, token: token))
        let reopened = try TranscriptJournal(sessionID: id, directory: root)
        try check(await reopened.completedThrough()[.caller] == 90)
        try check(await reopened.completedThrough()[.agent] == 0)
        let resource = TranscriptCompletion(
            finalizedSources: [.agent],
            states: [.agent: TranscriptSideState(side: .agent, speech: .resourceLimit, translation: .ready)])
        try check(resource.drainedSources.isEmpty && resource.states[.agent]?.speech == .resourceLimit)
        // No start call: this tests the actual stop join without touching models.
        let idleEngine = LiveTranscriptEngine()
        let stops = await withTaskGroup(of: TranscriptCompletion.self, returning: [TranscriptCompletion].self)
        { group in
            for _ in 0..<8 { group.addTask { await idleEngine.stop() } }
            var values: [TranscriptCompletion] = []
            for await value in group { values.append(value) }
            return values
        }
        try check(stops.count == 8)
        try check(stops.allSatisfy { $0.drainedSources.isEmpty && $0.states.isEmpty && !$0.wasCancelled })
    }

    func staleAndInvalidCheckpointsCannotReplaceDurableProgress() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try TranscriptJournal(sessionID: UUID(), directory: root)
        let stale = await journal.beginGeneration()
        let current = await journal.beginGeneration()
        let completion = TranscriptCompletion(
            finalizedSources: [.caller],
            states: [.caller: TranscriptSideState(side: .caller, speech: .ready, translation: .notNeeded)])
        try check(await journal.prepareCheckpoints(durationFrames: 100, token: current))
        try check(
            !(await journal.commitCompletedThrough(
                [.caller: 50], completion: completion, durationFrames: 100, token: stale)))
        try check(
            await journal.commitCompletedThrough(
                [.caller: 50], completion: completion, durationFrames: 100, token: current))
        let bytes = try Data(contentsOf: root.appendingPathComponent("transcript.json"))
        for invalid in [-1, 49, 101, Int64.max] {
            var rejected = false
            do {
                _ = try await journal.commitCompletedThrough(
                    [.caller: invalid], completion: completion, durationFrames: 100, token: current)
            } catch { rejected = true }
            try check(rejected)
        }
        try check(Data(contentsOf: root.appendingPathComponent("transcript.json")) == bytes)
        for checkpoint in [
            ["caller": Int64(-1)], ["caller": TranscriptLimits.maximumFrame + 1], ["unknown": Int64(0)],
        ] {
            var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            object["completedThrough"] = checkpoint
            try JSONSerialization.data(withJSONObject: object).write(
                to: root.appendingPathComponent("transcript.json"))
            var rejected = false
            do { _ = try TranscriptJournal(sessionID: current.sessionID, directory: root) } catch {
                rejected = true
            }
            try check(rejected)
        }
    }

    func repeatedResumePreservesFinalsAndExhaustedRanges() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let journal = try TranscriptJournal(sessionID: id, directory: root)
        let token = await journal.beginGeneration()
        try check(await journal.prepareCheckpoints(durationFrames: 50, token: token))
        let final = entry(side: .caller, start: 0, end: 20)
        try check(await journal.upsert(final, token: token))
        let completion = TranscriptCompletion(
            finalizedSources: Set(AudioSide.allCases),
            states: Dictionary(
                uniqueKeysWithValues: AudioSide.allCases.map {
                    ($0, TranscriptSideState(side: $0, speech: .ready, translation: .notNeeded))
                }))
        try check(
            await journal.commitCompletedThrough(
                [.caller: 50, .agent: 50], completion: completion, durationFrames: 50, token: token))
        var audio = RecordingManifest(id: id, title: "Saved", owner: .manual)
        audio.durationFrames = 50
        audio.segments = [RecordingSegment(side: .caller, filename: "caller.caf", startFrame: 0, frames: 50)]
        for _ in 0..<3 {
            let reopened = try TranscriptJournal(sessionID: id, directory: root)
            let ranges = try StoredTranscriptProcessor.eligibleIntervals(
                manifest: audio, session: nil, completedThrough: await reopened.completedThrough(),
                finalEntries: await reopened.snapshot())
            try check(ranges.values.allSatisfy(\.isEmpty))
            try check(await reopened.snapshot() == [final])
        }
    }

    func interruptedTranslationNeedsActualTranslatedText() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let journal = try TranscriptJournal(sessionID: id, directory: root)
        let token = await journal.beginGeneration()
        var final = entry(side: .caller, start: 0, end: 20)
        final.translationStatus = .pending
        try check(await journal.upsert(final, token: token))
        let reopened = try TranscriptJournal(sessionID: id, directory: root)
        let interrupted = await reopened.snapshot()
        try check(interrupted.first?.translationStatus == .interrupted)
        try check(StoredTranscriptProcessor.retryableTranslations(interrupted).count == 1)
        let generation = await reopened.beginGeneration()
        var rejected = false
        do {
            _ = try await reopened.updateTranslation(
                entryID: final.id, original: final.original, translation: nil,
                status: .translated, token: generation)
        } catch { rejected = true }
        try check(rejected)
        try check(await reopened.snapshot().first?.translationStatus == .interrupted)
        try check(
            await reopened.updateTranslation(
                entryID: final.id, original: final.original, translation: "실제 번역",
                status: .translated, token: generation))
        try check(StoredTranscriptProcessor.retryableTranslations(await reopened.snapshot()).isEmpty)
    }

    private func check(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        try expect(value, file: file, line: line)
    }

    private func recording(session: SessionManifest) -> RecordingManifest {
        var result = RecordingManifest(
            id: session.id, title: session.title, createdAt: session.createdAt, owner: .manual)
        result.durationFrames = 50
        result.segments = [
            RecordingSegment(side: .caller, filename: "caller.caf", startFrame: 0, frames: 50),
            RecordingSegment(side: .agent, filename: "agent.caf", startFrame: 5, frames: 20),
        ]
        return result
    }

    private func entry(side: AudioSide, start: Int64, end: Int64) -> TranscriptEntry {
        TranscriptEntry(
            side: side, startFrame: start, endFrame: end, original: "Completed original", isFinal: true)
    }

    private func interval(_ start: Int64, _ frames: Int64) throws -> SessionInterval {
        try SessionInterval(startFrame: start, frames: frames)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "stored-text-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
