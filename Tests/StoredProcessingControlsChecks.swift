import AVFoundation
import BridgeCore
import Foundation
import RecorderKit
import TranscriptKit

@main struct Checks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("Saved.mihrecording")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = RecordingManifest(title: "Saved", owner: .manual)
        manifest.status = .complete
        manifest.durationFrames = 100
        try manifest.save(to: directory)
        let item = RecordingItem(directory: directory, manifest: manifest)
        let configuration = try TranscriptConfiguration(
            callerLocaleIdentifier: "en-US", agentLocaleIdentifier: "en-US", targetLocaleIdentifier: "en-US")
        let journal = try TranscriptJournal(sessionID: item.id, directory: directory)
        try await journal.setConfiguration(configuration)
        let token = await journal.beginGeneration()
        try await journal.upsert(
            TranscriptEntry(side: .caller, startFrame: 0, endFrame: 100, original: "Existing", isFinal: true),
            token: token)
        let original = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        let controller = StoredProcessingController()
        controller.start(item, mode: .translationOnly, configuration: configuration)
        while controller.busy { await Task.yield() }
        precondition(controller.record(for: item.id)?.phase == .review)
        precondition(controller.candidateEntries(for: item.id).first?.original == "Existing")
        precondition(!controller.busy)
        let beforeApply = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        precondition(beforeApply == original)
        let copyDirectory = root.appendingPathComponent("Copied.mihrecording")
        try FileManager.default.copyItem(at: directory, to: copyDirectory)
        let copy = try RecordingLibrary.item(at: copyDirectory)
        controller.apply(copy)
        precondition(!controller.busy)
        precondition(controller.record(for: item) != nil)
        precondition(controller.record(for: copy) == nil)
        let copiedCurrent = try Data(contentsOf: copyDirectory.appendingPathComponent("transcript.json"))
        precondition(copiedCurrent == original)
        let restored = StoredProcessingController()
        await restored.restore(item)
        precondition(restored.record(for: item.id)?.phase == .review)
        restored.apply(item)
        while restored.busy { await Task.yield() }
        precondition(restored.record(for: item.id) == nil)
        let applied = try TranscriptJournal.readArchive(sessionID: item.id, directory: directory)
        precondition(applied.entries.first?.translationStatus == .notNeeded)
        let current = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        restored.start(item, mode: .translationOnly, configuration: configuration)
        while restored.busy { await Task.yield() }
        precondition(restored.record(for: item)?.phase == .review)
        restored.discard(item)
        while restored.busy { await Task.yield() }
        precondition(restored.record(for: item) == nil)
        let afterDiscard = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        precondition(afterDiscard == current)
        print(
            "PASS saved controller restores review, protects copied sources, applies and discards candidates")
    }
}
