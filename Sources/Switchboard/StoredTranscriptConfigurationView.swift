import BridgeCore
import SwiftUI
import TranscriptKit

struct StoredTranscriptConfigurationView: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.appStrings) private var strings
    @Environment(\.dismiss) private var dismiss
    let mode: StoredTranscriptMode
    let initial: TranscriptConfiguration?
    let confirm: (TranscriptConfiguration) -> Void
    @ViewState private var caller = ""
    @ViewState private var agent = ""
    @ViewState private var target = ""
    @ViewState private var speechLanguages: [String] = []
    @ViewState private var translationLanguages: [String] = []
    private var configuration: TranscriptConfiguration? {
        try? TranscriptConfiguration(
            callerLocaleIdentifier: caller, agentLocaleIdentifier: agent, targetLocaleIdentifier: target)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(strings(mode == .translationOnly ? .reprocessingTranslate : .reprocessingConfigure)).font(
                typography.panelTitle
            ).accessibilityAddTraits(.isHeader).accessibilityInitialFocus()
            language(
                strings(.transcriptCallerLanguage), selection: $caller,
                choices: mode == .translationOnly ? translationLanguages : speechLanguages)
            language(
                strings(.transcriptAgentLanguage), selection: $agent,
                choices: mode == .translationOnly ? translationLanguages : speechLanguages)
            language(strings(.transcriptYourLanguage), selection: $target, choices: translationLanguages)
            if mode == .remaining {
                Text(strings(.reprocessingLanguageChange)).font(typography.caption).foregroundStyle(
                    .secondary)
            }
            HStack {
                Button(strings(.actionCancel)) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(strings(.actionStart)) {
                    if let configuration {
                        confirm(configuration)
                        dismiss()
                    }
                }.buttonStyle(.borderedProminent).disabled(configuration == nil).keyboardShortcut(
                    .defaultAction)
            }
        }.padding(24).frame(minWidth: 420, idealWidth: 520, maxWidth: 680)
            .task {
                caller = initial?.callerLocaleIdentifier ?? ""
                agent = initial?.agentLocaleIdentifier ?? ""
                target = initial?.targetLocaleIdentifier ?? ""
                async let speech = TranscriptCapabilities.supportedSpeechLocaleIdentifiers()
                async let translation = TranscriptCapabilities.supportedTranslationLanguageIdentifiers()
                let choices = await (speech, translation)
                guard !Task.isCancelled else { return }
                speechLanguages = choices.0
                translationLanguages = choices.1
            }
    }
    private func language(_ label: String, selection: Binding<String>, choices: [String]) -> some View {
        let canonical = Binding(
            get: {
                choices.first(where: { localeKey($0) == localeKey(selection.wrappedValue) })
                    ?? selection.wrappedValue
            },
            set: { selection.wrappedValue = $0 })
        return VStack(alignment: .leading, spacing: 8) {
            Text(label).font(typography.caption).foregroundStyle(.secondary)
            Picker(label, selection: canonical) {
                Text(strings(.transcriptChooseLanguage)).tag("")
                if !selection.wrappedValue.isEmpty
                    && !choices.contains(where: { localeKey($0) == localeKey(selection.wrappedValue) })
                {
                    Text(
                        strings.locale.localizedString(forIdentifier: selection.wrappedValue)
                            ?? selection.wrappedValue
                    ).tag(selection.wrappedValue)
                }
                ForEach(choices, id: \.self) { value in
                    Text(strings.locale.localizedString(forIdentifier: value) ?? value).tag(value)
                }
            }.labelsHidden()
        }
    }
    private func localeKey(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

}
