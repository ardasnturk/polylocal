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
                Text("Live subtitles for what the other participants say, translated into \(settings.meetingLanguage.localizedName). Start it from the menu bar: Meeting subtitles. Audio is processed on this Mac and never saved or sent; text is saved only if you turn on notes below.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Languages") {
                Picker("They speak", selection: $settings.meetingTheirLanguage) {
                    Text("Detect automatically").tag(Language?.none)
                    ForEach(Language.all) { Text($0.localizedName).tag(Language?.some($0)) }
                }
                Picker("Subtitles in", selection: $settings.meetingMyLanguage) {
                    Text("Primary language (\(settings.primaryLanguage.localizedName))").tag(Language?.none)
                    Divider()
                    ForEach(Language.all) { Text($0.localizedName).tag(Language?.some($0)) }
                }
                Text("Subtitles, notes and the spoken translation are in this language; it is also the language you speak when Polylocal speaks the translation for you. Choosing the language they speak is a little faster and more reliable than detecting it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hear the translation instead of the original", isOn: Binding(
                    get: { settings.meetingHearTranslation },
                    set: { app.meeting.setHearingTranslation($0) }))
                LabeledContent("Voice") {
                    Text(MeetingVoice.voice(for: settings.meetingLanguage)?.name ?? String(localized: "None installed"))
                        .foregroundStyle(.secondary)
                }
                if MeetingVoice.hasOnlyBasicVoice(for: settings.meetingLanguage) {
                    HStack {
                        Text("Only the basic \(settings.meetingLanguage.localizedName) voice is installed. Enhanced and Premium voices sound much more natural.")
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

            SpeakTranslationSection(app: app)

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

/// Level 4: the user's speech, translated and spoken into the Polylocal Microphone.
private struct SpeakTranslationSection: View {
    let app: AppModel

    var body: some View {
        @Bindable var settings = app.settings
        let driver = app.microphoneDriver
        let their = app.meeting.theirLanguage
        Section {
            LabeledContent("Polylocal Microphone") {
                if driver.isWorking {
                    ProgressView().controlSize(.small)
                } else if driver.isInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Uninstall…") { driver.uninstall() }
                } else if driver.isAvailable {
                    Button("Install…") { driver.install() }
                } else {
                    Text("Not included in this build").foregroundStyle(.secondary)
                }
            }
            if let error = driver.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            }
            Toggle("Start automatically when a meeting app uses Polylocal Microphone", isOn: $settings.meetingAutoStart)
                .disabled(!driver.isInstalled)
            Toggle("Also when I start meeting subtitles from the menu bar", isOn: $settings.meetingSpeakTranslation)
                .disabled(!driver.isInstalled)
            // The same setting as "They speak" above: the others hear their own language.
            Picker("They hear", selection: $settings.meetingTheirLanguage) {
                Text("The language they speak (until known: \(their.localizedName))").tag(Language?.none)
                Divider()
                ForEach(Language.all) { Text($0.localizedName).tag(Language?.some($0)) }
            }
            if settings.meetingTheirLanguage == nil {
                Label("Choose their language so your first sentences are not spoken in \(their.localizedName).",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Voice") {
                Text(MeetingVoice.voice(for: their)?.name ?? String(localized: "None installed"))
                    .foregroundStyle(.secondary)
            }
            if their.hasFormality {
                LabeledContent("Form of address") {
                    FormalityPicker(formality: Binding(get: { settings.formality(for: their) },
                                                       set: { settings.formalityByLanguage[their.code] = $0 }),
                                    language: their)
                }
            }
        } header: {
            HStack {
                Text("Speak the translation")
                Text("Beta").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.orange.opacity(0.2), in: Capsule()).foregroundStyle(.orange)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("How to use it:").fontWeight(.semibold)
                Text("1. Install Polylocal Microphone (administrator password once; the Mac's audio restarts briefly).")
                Text("2. Choose the language they speak above.")
                Text("3. In Zoom, Meet or Teams, choose “Polylocal Microphone” as the microphone and join the call.")
                Text("4. Polylocal starts by itself: speak your language, and they hear the translation about 3 seconds later. The subtitle bar shows what they heard.")
                Text("Use headphones. “Speaking translation” in the subtitle bar switches to your own voice and back.")
                    .padding(.top, 2)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { driver.refresh() }
    }
}
