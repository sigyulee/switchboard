// SPDX-License-Identifier: AGPL-3.0-only
import BridgeCore
import Darwin
import Foundation

private struct AccessibilityCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AccessibilityCheckFailure(description: message) }
}

@main @MainActor struct AccessibilityChecks {
    static func main() throws {
        let checks: [(String, () throws -> Void)] = [
            ("announcements ignore empty text and deduplicate unchanged state", announcementDeduplication),
            ("changed state and independent events remain announceable", announcementIdentity),
            ("recovering clears the previous error announcement", announcementRecovery),
            ("announcement history stays bounded across many transcripts", boundedAnnouncementHistory),
            ("existing and partial transcript entries stay quiet", transcriptInitialAndPartial),
            ("a finalized transcript entry is announced exactly once", transcriptFinalization),
            ("status kinds remain distinguishable without color", nonColorStatusKinds),
            ("session announcements describe meaningful transitions", sessionTransitions),
            ("recording and transcript summaries preserve reading order", semanticSummaries),
            ("interactive icon targets scale from a 44 point minimum", controlTargets),
            ("audio capture states distinguish quiet input from pause and failure", audioStates),
        ]
        var failures = 0
        for (name, check) in checks {
            do {
                try check()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }
        if failures > 0 { exit(1) }
        print("\(checks.count) accessibility behavior checks passed.")
    }

    private static func announcementDeduplication() throws {
        var posted: [AppAccessibilityAnnouncement] = []
        let announcer = AccessibilityAnnouncer { posted.append($0) }
        announcer.announce(id: "session", message: "   ", priority: .high)
        announcer.announce(id: "session", message: "Session paused", priority: .high)
        announcer.announce(id: "session", message: "Session paused", priority: .high)
        try require(posted.count == 1, "an empty or unchanged announcement was posted")
        try require(posted.first?.message == "Session paused", "the readable message was changed")
        try require(posted.first?.priority == .high, "the requested priority was lost")
    }

    private static func announcementIdentity() throws {
        var posted: [AppAccessibilityAnnouncement] = []
        let announcer = AccessibilityAnnouncer { posted.append($0) }
        announcer.announce(id: "session", message: "Paused", priority: .high)
        announcer.announce(id: "session", message: "Resumed", priority: .low)
        announcer.announce(id: "recording", message: "Resumed", priority: .low)
        try require(posted.map(\.id) == ["session", "session", "recording"], "event identity collapsed")
        try require(posted.map(\.priority) == [.high, .low, .low], "event priority changed")
        announcer.reset(id: "session")
        announcer.announce(id: "session", message: "Resumed", priority: .low)
        try require(posted.count == 4, "reset did not make the current state announceable")
    }

    private static func announcementRecovery() throws {
        var posted: [AppAccessibilityAnnouncement] = []
        let announcer = AccessibilityAnnouncer { posted.append($0) }
        announcer.announce(id: "capture", message: "Device disconnected")
        announcer.announce(id: "capture", message: "")
        announcer.announce(id: "capture", message: "Device disconnected")
        try require(posted.count == 2, "the same error was suppressed after recovery")
    }

    private static func boundedAnnouncementHistory() throws {
        var posted: [AppAccessibilityAnnouncement] = []
        let announcer = AccessibilityAnnouncer { posted.append($0) }
        for index in 0..<128 {
            announcer.announce(id: "transcript.\(index)", message: "Entry \(index)")
        }
        announcer.announce(id: "transcript.127", message: "Entry 127")
        try require(posted.count == 128, "the most recent entry lost duplicate protection")
        announcer.announce(id: "transcript.0", message: "Entry 0")
        try require(posted.count == 129, "old transcript text remained in the announcement cache")
    }

    private static func nonColorStatusKinds() throws {
        let kinds = AccessibleStatusKind.allCases
        try require(Set(kinds.map(\.symbolName)).count == kinds.count, "status symbols are ambiguous")
        try require(
            kinds.allSatisfy { !$0.symbolName.isEmpty }, "a status relies on color without a symbol")
    }

    private static func sessionTransitions() throws {
        let idle = AccessibilitySessionSnapshot(
            active: false, running: false, paused: false, pauseReason: nil,
            recording: false, transcription: false)
        let running = AccessibilitySessionSnapshot(
            active: true, running: true, paused: false, pauseReason: nil,
            recording: true, transcription: true)
        try require(
            AccessibilitySessionSnapshot.events(from: nil, to: running).isEmpty,
            "initial state produced announcements")
        try require(
            AccessibilitySessionSnapshot.events(from: idle, to: running) == [.started],
            "session start produced noisy or missing announcements")
        let recordingOff = AccessibilitySessionSnapshot(
            active: true, running: true, paused: false, pauseReason: nil,
            recording: false, transcription: true)
        try require(
            AccessibilitySessionSnapshot.events(from: running, to: recordingOff) == [.recordingStopped],
            "recording intent change was not announced")
        let paused = AccessibilitySessionSnapshot(
            active: true, running: false, paused: true, pauseReason: .manual,
            recording: false, transcription: true)
        try require(
            AccessibilitySessionSnapshot.events(from: recordingOff, to: paused) == [.paused],
            "manual pause was not announced")
        let disconnected = AccessibilitySessionSnapshot(
            active: true, running: false, paused: true, pauseReason: .callerDisconnected,
            recording: false, transcription: true)
        try require(
            AccessibilitySessionSnapshot.events(from: running, to: disconnected) == [.disconnected],
            "caller disconnection was described as a generic pause")
        try require(
            AccessibilitySessionSnapshot.events(from: paused, to: recordingOff) == [.resumed],
            "resume was not announced")
        try require(
            AccessibilitySessionSnapshot.events(from: running, to: idle) == [.ended],
            "session end was not announced")
    }

    private static func audioStates() throws {
        func state(
            ready: Bool = true, level: Float = 0, paused: Bool = false,
            disconnected: Bool = false, failed: Bool = false
        ) -> AudioCaptureAccessibilityState {
            AudioCaptureAccessibilityPresentation(
                ready: ready, level: level, paused: paused, disconnected: disconnected,
                failed: failed
            ).state
        }
        try require(state(level: 0.1) == .receiving, "active input was not detected")
        try require(state(level: 0) == .quiet, "quiet input was mislabeled")
        try require(state(level: 0, paused: true) == .paused, "pause was described as quiet input")
        try require(state(level: 0.1, disconnected: true) == .disconnected, "disconnect was hidden")
        try require(state(ready: false) == .unavailable, "missing route was described as quiet input")
        try require(
            state(ready: false, disconnected: true, failed: true) == .failed,
            "an audio error did not take priority")
    }

    private static func controlTargets() throws {
        try require(
            AppTypography().controlSide >= 44,
            "an icon target is smaller than 44 points")
    }

    private static func semanticSummaries() throws {
        let recording = RecordingAccessibilitySummary(
            date: "9/16/2026", duration: "01:06", status: "Processing paused")
        try require(
            recording.value == "9/16/2026, 01:06, Processing paused",
            "recording metadata reading order changed")
        let final = TranscriptAccessibilitySummary(
            speaker: "Caller", timestamp: "00:01", original: "Hello",
            translation: "안녕하세요", translationLabel: "Translation", partialLabel: nil)
        try require(
            final.label == "Caller, 00:01, Hello, Translation: 안녕하세요",
            "final transcript reading order changed")
        let partial = TranscriptAccessibilitySummary(
            speaker: "Agent", timestamp: "00:02", original: "Working", translation: nil,
            translationLabel: "Translation", partialLabel: "In progress")
        try require(
            partial.label == "Agent, 00:02, Working, In progress",
            "partial transcript status is missing or out of order")
    }

    private static func transcriptInitialAndPartial() throws {
        let existing = entry(id: UUID(), text: "Already visible", final: true)
        let partial = entry(id: UUID(), text: "Still listening", final: false)
        var tracker = TranscriptAnnouncementTracker(existing: [existing, partial])
        try require(
            tracker.newlyFinalized(in: [existing, partial]).isEmpty, "initial entries were announced")
        var updatedPartial = partial
        updatedPartial.original = "Still listening now"
        try require(
            tracker.newlyFinalized(in: [existing, updatedPartial]).isEmpty,
            "a partial hypothesis was announced")
    }

    private static func transcriptFinalization() throws {
        let id = UUID()
        let partial = entry(id: id, text: "Hello", final: false)
        var tracker = TranscriptAnnouncementTracker(existing: [partial])
        var final = partial
        final.original = "Hello there"
        final.isFinal = true
        try require(tracker.newlyFinalized(in: [final]) == [final], "final text was not announced")
        var translated = final
        translated.translation = "안녕하세요"
        translated.translationStatus = .translated
        try require(
            tracker.newlyFinalized(in: [translated]).isEmpty,
            "a translation update repeated the final announcement")
        let second = entry(id: UUID(), text: "Second", final: true)
        try require(
            tracker.newlyFinalized(in: [translated, second]) == [second],
            "the next final entry did not produce one announcement")
    }

    private static func entry(id: UUID, text: String, final: Bool) -> TranscriptEntry {
        TranscriptEntry(
            id: id, side: .caller, startFrame: 0, endFrame: 48_000, original: text,
            isFinal: final)
    }
}
