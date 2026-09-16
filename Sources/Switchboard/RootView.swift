import SwiftUI

struct RootView: View {
    private var typography: AppTypography { AppTypography() }
    @Environment(\.appStrings) private var strings
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AppModel
    @ViewState private var findController = AppFindController()
    @ViewState private var accessibilityAnnouncementsInitialized = false
    var body: some View {
        Group {
            if model.language == nil {
                LanguageChoiceView(choose: model.chooseLanguage)
            } else if model.needsRecordingFolderSetup {
                RecordingFolderSetupView(
                    folder: model.recordingRoot, busy: model.recordingFolderBusy,
                    issue: model.recordingFolderIssue, choose: model.chooseRecordingFolder,
                    confirm: { model.useRecordingFolder(model.recordingRoot) })
            } else {
                content
            }
        }
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
        .environment(\.appTypography, typography)
        .environment(findController)
        .focusedSceneValue(\.appFindController, findController)
        .onChange(of: model.page) { findController.focusLibrary() }
        .onChange(of: accessibilitySession, initial: true) { previous, current in
            guard accessibilityAnnouncementsInitialized else {
                accessibilityAnnouncementsInitialized = true
                return
            }
            announce(AccessibilitySessionSnapshot.events(from: previous, to: current))
        }
        .onChange(of: model.callerCaptureError) { _, error in
            model.accessibilityAnnouncer.announce(
                id: "audio.caller.error", message: error.map { strings.error($0) }, priority: .high)
        }
        .onChange(of: model.agentCaptureError) { _, error in
            model.accessibilityAnnouncer.announce(
                id: "audio.agent.error", message: error.map { strings.error($0) }, priority: .high)
        }
        .onChange(of: model.transcript.error) { _, error in
            model.accessibilityAnnouncer.announce(id: "transcript.error", message: error, priority: .high)
        }
        .onChange(of: model.driverIssue) { _, issue in
            model.accessibilityAnnouncer.announce(
                id: "setup.driver.error", message: issue.map { strings($0.message) }, priority: .high)
        }
        .onChange(of: model.captureAccessIssue) { _, issue in
            model.accessibilityAnnouncer.announce(
                id: "setup.capture.error", message: issue.map { strings($0.message) }, priority: .high)
        }
        .onChange(of: model.monitorError) { _, error in
            model.accessibilityAnnouncer.announce(
                id: "monitor.error", message: error.map { strings.error($0) }, priority: .high)
        }
        .onChange(of: model.recordingFolderIssue) { _, issue in
            model.accessibilityAnnouncer.announce(
                id: "folder.error", message: issue.map { strings($0.message) }, priority: .high)
        }
        .onChange(of: model.errorMessage) { _, message in
            model.accessibilityAnnouncer.announce(id: "app.error", message: message, priority: .high)
        }
    }
    private var accessibilitySession: AccessibilitySessionSnapshot {
        AccessibilitySessionSnapshot(
            active: model.session.active, running: model.session.running, paused: model.session.paused,
            pauseReason: model.session.pauseReason, recording: model.session.audioRecordingEnabled,
            transcription: model.session.transcriptionEnabled)
    }

    private func announce(_ events: [AccessibilitySessionEvent]) {
        for event in events {
            let (id, key, priority): (String, TextKey, AppAccessibilityAnnouncementPriority) =
                switch event {
                case .started: ("session.state", .accessibilitySessionStarted, .low)
                case .ended: ("session.state", .accessibilitySessionEnded, .low)
                case .paused: ("session.state", .accessibilitySessionPaused, .medium)
                case .resumed: ("session.state", .accessibilitySessionResumed, .low)
                case .disconnected: ("session.state", .accessibilitySessionDisconnected, .high)
                case .recordingStarted: ("session.recording", .accessibilityRecordingStarted, .low)
                case .recordingStopped: ("session.recording", .accessibilityRecordingStopped, .low)
                case .transcriptionStarted:
                    ("session.transcription", .accessibilityTranscriptionStarted, .low)
                case .transcriptionStopped:
                    ("session.transcription", .accessibilityTranscriptionStopped, .low)
                }
            model.accessibilityAnnouncer.announce(
                id: id, message: strings(key), priority: priority)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            if model.preview {
                Label(strings(.previewNotice), systemImage: "eye")
                    .font(typography.caption).foregroundStyle(.secondary).padding(.bottom, 12)
            }
            Divider()
            if model.page == "library" {
                LibraryView(model: model)
            } else if model.openingDraft {
                ProgressView(strings(.sessionOpening))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.session.closed {
                ClosedSessionView(model: model)
            } else if model.page == "session" {
                if model.session.hasSession {
                    ActiveSessionView(model: model)
                } else {
                    ScrollView { SessionHomeView(model: model).padding(32) }
                }
            } else {
                LibraryView(model: model)
            }
        }
        .frame(minWidth: 860, minHeight: 620)
        .font(typography.body)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showSetup) {
            SettingsSurface(width: 600, maximumHeight: 620) { SetupView(model: model) }
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsSurface(width: 620) { SettingsView(model: model) }
        }
        .confirmationDialog(
            strings(.sessionEndTitle), isPresented: $model.showEndSession, titleVisibility: .visible
        ) {
            Button(strings(.actionSave)) { model.saveSession() }
            Button(strings(.actionDiscard), role: .destructive) { model.discardSession() }
            Button(strings(.actionCancel), role: .cancel) { model.session.cancelEnd() }
        }
        .alert(
            strings(.alertTitle),
            isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button(strings(.actionOk), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            SwitchboardMark().frame(width: 44, height: 44)
            Text("Switchboard").font(typography.title).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 20)
            Picker(
                strings(.navigationView),
                selection: Binding(get: { model.page }, set: { model.navigate(to: $0) })
            ) {
                Text(strings(.navigationSession)).tag("session")
                Text(strings(.navigationRecordings)).tag("library")
            }.pickerStyle(.segmented).controlSize(.large).font(typography.body)
                .labelsHidden().fixedSize()
                .disabled(model.openingDraft || model.endingSession)
            IconButton("gearshape", label: strings(.navigationSettings)) {
                model.showSettings = true
            }
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }
}
