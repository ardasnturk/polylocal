import AppKit
import SwiftUI
import PolylocalCore

/// Settings → Meeting: speech model, languages and subtitle options.
struct MeetingSettingsView: View {
    let app: AppModel
    @State private var showConsent = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                if let model = app.meeting.speechModel {
                    ModelRow(app: app, model: model)
                }
                if !MeetingController.isSupported {
                    Label("Meeting mode needs macOS 14.2 or later and a build that includes whisper-server.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Speech recognition")
            } footer: {
                Text("Live subtitles for what the other participants say, translated into \(settings.primaryLanguage.localizedName). Start it from the menu bar: Meeting subtitles. Audio is processed on this Mac and never saved or sent; text is saved only if you turn on notes below.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Languages") {
                Picker("They speak", selection: $settings.meetingTheirLanguage) {
                    Text("Detect automatically").tag(Language?.none)
                    ForEach(Language.all) { Text($0.localizedName).tag(Language?.some($0)) }
                }
                LabeledContent("Subtitles in", value: settings.primaryLanguage.localizedName)
                Text("Choosing the language is a little faster and more reliable than detecting it. The subtitle language is your primary language (General).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hear the translation instead of the original", isOn: Binding(
                    get: { settings.meetingHearTranslation },
                    set: { app.meeting.setHearingTranslation($0) }))
                LabeledContent("Voice") {
                    Text(MeetingVoice.voice(for: settings.primaryLanguage)?.name ?? String(localized: "None installed"))
                        .foregroundStyle(.secondary)
                }
                if MeetingVoice.hasOnlyBasicVoice(for: settings.primaryLanguage) {
                    HStack {
                        Text("Only the basic \(settings.primaryLanguage.localizedName) voice is installed. Enhanced and Premium voices sound much more natural.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Get voices…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpeakableItems")!)
                        }
                    }
                }
            } header: {
                Text("Hear the translation")
            } footer: {
                Text("The meeting app goes silent for you and Polylocal speaks the translation, about two seconds behind. Use headphones, or the others will hear the translation through your microphone. You can switch back to the original in the subtitle bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Save meeting notes", isOn: Binding(
                    get: { settings.meetingSaveNotes },
                    set: { on in
                        if on, !settings.meetingSaveNotes { showConsent = true } else { settings.meetingSaveNotes = on }
                    }))
                LabeledContent("Folder") {
                    Text(app.meeting.notesRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…", action: chooseFolder)
                    Button("Open") { openFolder(app.meeting.notesRoot) }
                }
                Toggle("Write a summary after the meeting", isOn: $settings.meetingSummarize)
                    .disabled(!settings.meetingSaveNotes)
            } header: {
                Text("Notes")
            } footer: {
                Text("Each meeting gets a folder with the original and translated transcript (Markdown and JSON) and, optionally, a summary with decisions and action items, written by the local model. Audio is never saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .alert("Save meeting notes?", isPresented: $showConsent) {
                Button("Save notes") { settings.meetingSaveNotes = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Polylocal will save what the other participants say as text on this Mac. In many places, transcribing a conversation requires the consent of everyone in it. Let the other participants know.")
            }

            Section("Subtitles") {
                Toggle("Show the original under the translation", isOn: $settings.meetingShowOriginal)
                LabeledContent("Text size") {
                    Slider(value: $settings.meetingFontSize, in: 14...44, step: 2)
                        .frame(width: 200)
                    Text("\(Int(settings.meetingFontSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = app.meeting.notesRoot.deletingLastPathComponent()
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { app.settings.meetingNotesFolder = url.path }
    }

    private func openFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(url)
    }
}
