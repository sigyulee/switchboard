import RecorderKit
import SwiftUI

struct ClosedSessionView: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    @Environment(AppFindController.self) private var findController
    @Bindable var model: AppModel
    @ViewState private var fallbackTranscriptID = UUID()
    @ViewState private var recording: RecordingItem?
    private var transcriptID: UUID { model.session.sessionID ?? fallbackTranscriptID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                SessionHeading(
                    name: model.session.sessionName,
                    description: model.session.sessionDescription,
                    duration: model.session.duration)
                Spacer()
                if recording == nil && !model.transcript.entries.isEmpty {
                    IconButton("magnifyingglass", label: strings(.transcriptSearch)) {
                        findController.findTranscript(owner: transcriptID)
                    }
                }
            }.padding(24)
            Divider()
            if let recording {
                SavedTranscriptView(
                    item: recording,
                    seek: { model.play(recording, side: model.playback.source.side, at: $0) },
                    processing: model.storedProcessing,
                    canProcess: !model.preview && !model.session.active && !model.starting
                        && !model.endingSession && !model.session.busy && model.libraryMutationTask == nil
                        && !model.exportBusy,
                    continueProcessing: model.continueProcessing,
                    announcer: model.accessibilityAnnouncer,
                    defaultConfiguration: model.transcript.configuration,
                    startProcessing: model.processStored
                ).id("\(recording.id)-\(recording.directory.path)").padding(24)
            } else if model.transcript.entries.isEmpty {
                Text(strings(.libraryNoTranscript)).font(typography.body).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptMessages(transcriptID: transcriptID, entries: model.transcript.entries)
                    .id(transcriptID)
            }
            Divider()
            HStack(spacing: 16) {
                Button(strings(.actionBack)) { model.closeSessionView() }
                Spacer()
                Button(strings(.actionDiscard), role: .destructive) { model.discardSession() }
                Button(strings(.actionSave)) { model.saveSession() }.buttonStyle(.borderedProminent)
            }.controlSize(.large).padding(24).disabled(model.session.busy || model.endingSession)
        }
        .task(id: model.session.directory) {
            recording = nil
            guard let directory = model.session.directory else { return }
            let item = try? await Task.detached(priority: .utility) {
                try RecordingLibrary.item(at: directory)
            }.value
            if !Task.isCancelled { recording = item }
        }
    }
}
