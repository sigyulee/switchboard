import AppKit
import BridgeCore
import Foundation
import SwiftUI

enum AppAccessibilityAnnouncementPriority: Equatable {
    case low, medium, high

    fileprivate var systemValue: NSAccessibilityPriorityLevel {
        switch self {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }
}

struct AppAccessibilityAnnouncement: Equatable {
    let id: String
    let message: String
    let priority: AppAccessibilityAnnouncementPriority
}

@MainActor final class AccessibilityAnnouncer {
    typealias Sink = @MainActor (AppAccessibilityAnnouncement) -> Void

    private let post: Sink
    private var lastMessageByID: [String: String] = [:]
    private var rememberedIDs: [String] = []

    init(post: @escaping Sink = AccessibilityAnnouncer.postToSystem) {
        self.post = post
    }

    func announce(
        id: String, message: String?, priority: AppAccessibilityAnnouncementPriority = .medium
    ) {
        guard !id.isEmpty else { return }
        let message = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty else {
            reset(id: id)
            return
        }
        guard lastMessageByID[id] != message else { return }
        if lastMessageByID[id] == nil {
            if rememberedIDs.count == 64 {
                lastMessageByID[rememberedIDs.removeFirst()] = nil
            }
            rememberedIDs.append(id)
        }
        lastMessageByID[id] = message
        post(AppAccessibilityAnnouncement(id: id, message: message, priority: priority))
    }

    func reset(id: String) {
        lastMessageByID[id] = nil
        rememberedIDs.removeAll { $0 == id }
    }

    private static func postToSystem(_ announcement: AppAccessibilityAnnouncement) {
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [
                .announcement: announcement.message,
                .priority: announcement.priority.systemValue.rawValue,
            ])
    }
}

struct TranscriptAnnouncementTracker {
    private var announcedFinalIDs: Set<UUID>

    init(existing entries: [TranscriptEntry] = []) {
        announcedFinalIDs = Set(entries.lazy.filter(\.isFinal).map(\.id))
    }

    mutating func newlyFinalized(in entries: [TranscriptEntry]) -> [TranscriptEntry] {
        let result = entries.filter { $0.isFinal && !announcedFinalIDs.contains($0.id) }
        announcedFinalIDs.formUnion(result.map(\.id))
        return result
    }
}

enum AccessibilitySessionEvent: Equatable {
    case started, ended, paused, resumed, disconnected
    case recordingStarted, recordingStopped, transcriptionStarted, transcriptionStopped
}

struct AccessibilitySessionSnapshot: Equatable {
    let active: Bool
    let running: Bool
    let paused: Bool
    let pauseReason: SessionPauseReason?
    let recording: Bool
    let transcription: Bool

    static func events(
        from previous: AccessibilitySessionSnapshot?, to current: AccessibilitySessionSnapshot
    ) -> [AccessibilitySessionEvent] {
        guard let previous else { return [] }
        if !previous.active && current.active { return current.running ? [.started] : [] }
        if previous.active && !current.active { return [.ended] }
        if !previous.paused && current.paused {
            return [current.pauseReason == .callerDisconnected ? .disconnected : .paused]
        }
        if previous.paused && current.running { return [.resumed] }
        var result: [AccessibilitySessionEvent] = []
        if previous.recording != current.recording {
            result.append(current.recording ? .recordingStarted : .recordingStopped)
        }
        if previous.transcription != current.transcription {
            result.append(current.transcription ? .transcriptionStarted : .transcriptionStopped)
        }
        return result
    }
}

struct RecordingAccessibilitySummary {
    let date: String
    let duration: String
    let status: String?

    var value: String { Self.joined([date, duration, status]) }

    fileprivate static func joined(_ values: [String?]) -> String {
        values.compactMap { rawValue in
            guard let rawValue else { return nil }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }.joined(separator: ", ")
    }
}

struct TranscriptAccessibilitySummary {
    let speaker: String
    let timestamp: String
    let original: String
    let translation: String?
    let translationLabel: String
    let partialLabel: String?

    var label: String {
        let translated = translation.flatMap { value -> String? in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return "\(translationLabel): \(value)"
        }
        return RecordingAccessibilitySummary.joined([
            speaker, timestamp, original, translated, partialLabel,
        ])
    }
}

private struct AccessibilityInitialFocusModifier: ViewModifier {
    @AccessibilityFocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.accessibilityFocused($focused).task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            focused = true
        }
    }
}

extension View {
    func accessibilityInitialFocus() -> some View {
        modifier(AccessibilityInitialFocusModifier())
    }
}
