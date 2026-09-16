import BridgeCore
import RecorderKit
import SwiftUI
import TranscriptKit

struct SavedTranscriptView: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    @Environment(AppFindController.self) private var findController
    let item: RecordingItem
    let seek: (Double) -> Void
    @Bindable var processing: StoredProcessingController
    let canProcess: Bool
    let continueProcessing: (RecordingItem) -> Void
    let announcer: AccessibilityAnnouncer
    let defaultConfiguration: TranscriptConfiguration?
    let startProcessing: (RecordingItem, StoredTranscriptMode, TranscriptConfiguration) -> Void
    @ViewState private var canResume = false
    @ViewState private var archiveLoaded = false
    @ViewState private var entries: [TranscriptEntry] = []
    @ViewState private var description = ""
    @ViewState private var error: String?
    @ViewState private var configuration: TranscriptConfiguration?
    private struct ConfigurationRequest: Identifiable {
        let id = UUID()
        let mode: StoredTranscriptMode
        let configuration: TranscriptConfiguration?
    }
    @ViewState private var configurationRequest: ConfigurationRequest?
    @ViewState private var showNewResult = true
    private var work: StoredTranscriptWorkRecord? { processing.record(for: item) }
    private var closedSource: Bool {
        item.manifest.status != .recording && item.manifest.status != .finalizing
    }
    private var busyHere: Bool { processing.isWriting(item) }
    private var transcriptOwner: UUID { showNewResult ? work?.id ?? item.id : item.id }
    private var visibleEntries: [TranscriptEntry] {
        work != nil && showNewResult ? processing.candidateEntries(for: item) : entries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !description.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(strings(.sessionDescriptionLabel)).foregroundStyle(.secondary)
                    Text(description).textSelection(.enabled)
                }.font(typography.caption).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(strings(.libraryTranscript)).font(typography.section).accessibilityAddTraits(.isHeader)
                Spacer()
                if work == nil {
                    if entries.isEmpty {
                        Button(strings(.reprocessingStart)) { configure(.fullTranscription) }
                            .disabled(!archiveLoaded || !canProcess || !closedSource || processing.busy)
                    } else {
                        Menu(strings(.reprocessingActions)) {
                            if canResume {
                                Button(strings(.libraryContinueTranscription)) { configure(.remaining) }
                            }
                            Button(strings(.reprocessingAgain)) { configure(.fullTranscription) }
                            Button(strings(.reprocessingTranslate)) { configure(.translationOnly) }
                        }.disabled(!archiveLoaded || !canProcess || !closedSource || processing.busy)
                    }
                }
                IconButton("magnifyingglass", label: strings(.transcriptSearch)) {
                    findController.findTranscript(owner: transcriptOwner)
                }.disabled(visibleEntries.isEmpty)
            }
            if busyHere && work == nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(strings(.reprocessingPreparing)).font(typography.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(strings(.actionPause)) { Task { await processing.pause() } }
                }
            }
            if let work {
                HStack(spacing: 10) {
                    if busyHere { ProgressView().controlSize(.small) }
                    Text(strings(work.phase.label)).font(typography.caption).foregroundStyle(.secondary)
                    Spacer()
                    if busyHere && work.phase.processing {
                        Button(strings(.actionPause)) { Task { await processing.pause() } }
                    } else if work.phase == .paused || work.phase == .failed {
                        Button(
                            strings(
                                work.phase == .failed ? .reprocessingRetry : .libraryContinueTranscription)
                        ) { continueProcessing(item) }
                        .disabled(!canProcess || !closedSource || processing.busy)
                    }
                }
                HStack {
                    if !entries.isEmpty {
                        Picker(strings(.reprocessingResults), selection: $showNewResult) {
                            Text(strings(.reprocessingCurrent)).tag(false)
                            Text(strings(.reprocessingNew)).tag(true)
                        }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    Spacer()
                    if work.phase == .review {
                        Button(strings(.reprocessingApply)) { processing.apply(item) }
                            .buttonStyle(.borderedProminent).disabled(
                                !canProcess || !closedSource || processing.busy)
                    }
                    Button(strings(.reprocessingDiscard)) { processing.discard(item) }.disabled(
                        processing.busy)
                }
            }
            if let issue = processing.issue(for: item) ?? error {
                InlineIssueView(message: strings(.reprocessingFailure), details: issue)
                if work == nil {
                    Button(strings(.reprocessingRetry)) { continueProcessing(item) }.disabled(
                        !canProcess || !closedSource || processing.busy)
                }
                if let work, work.phase == .failed {
                    Button(strings(.transcriptModels)) { processing.requiredModels = work.configuration }
                }
            }
            if !visibleEntries.isEmpty || busyHere {
                TranscriptMessages(
                    transcriptID: transcriptOwner, entries: visibleEntries, seek: seek,
                    isProcessing: showNewResult && busyHere && work?.phase.processing == true
                )
                .id(transcriptOwner)
                .frame(minHeight: 120, maxHeight: .infinity)
            } else {
                Text(strings(.libraryNoTranscript)).font(typography.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: showNewResult) { findController.focusTranscript(owner: transcriptOwner) }
        .onChange(of: work?.phase) { _, phase in
            if phase == .review {
                announcer.announce(
                    id: "processing.\(item.id.uuidString)",
                    message: strings(.accessibilityProcessingReady), priority: .low)
            } else if phase == .failed {
                announcer.announce(
                    id: "processing.\(item.id.uuidString)",
                    message: strings(.accessibilityProcessingFailed), priority: .high)
            } else {
                announcer.reset(id: "processing.\(item.id.uuidString)")
            }
        }
        .sheet(item: $configurationRequest) { request in
            StoredTranscriptConfigurationView(mode: request.mode, initial: request.configuration) { config in
                startProcessing(item, request.mode, config)
            }
        }
        .task(id: "\(item.id)-\(item.directory.path)-\(processing.revision)") {
            error = nil
            do {
                let result = try await Task.detached(priority: .utility) {
                    let journal = try TranscriptJournal(sessionID: item.id, directory: item.directory)
                    let session =
                        FileManager.default.fileExists(
                            atPath: item.directory.appendingPathComponent(SessionManifest.filename).path)
                        ? try SessionStore.metadata(in: item.directory) : nil
                    let progress = try await StoredTranscriptProcessor.progress(item: item, session: session)
                    return (
                        await journal.snapshot(), session?.description ?? "", progress.hasWork,
                        await journal.configuration()
                    )
                }.value
                guard !Task.isCancelled else { return }
                entries = result.0
                description = result.1
                canResume = result.2
                configuration = result.3
                archiveLoaded = true
                await processing.restore(item)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func configure(_ mode: StoredTranscriptMode) {
        configurationRequest = ConfigurationRequest(
            mode: mode, configuration: configuration ?? defaultConfiguration)
    }
}
