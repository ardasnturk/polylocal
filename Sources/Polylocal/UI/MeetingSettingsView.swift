import SwiftUI
import PolylocalCore

/// Settings → Meeting: speech model, languages and subtitle options.
struct MeetingSettingsView: View {
    let app: AppModel

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
                Text("Live subtitles for what the other participants say, translated into \(settings.primaryLanguage.localizedName). Start it from the menu bar: Meeting subtitles. Audio is processed on this Mac; nothing is recorded or sent.")
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
}
