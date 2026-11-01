import AppKit
import ServiceManagement
import SwiftUI
import PolylocalCore

enum SettingsTab: Hashable {
    case general, models, inline, meeting, glossary, about
}

struct SettingsView: View {
    @Bindable var app: AppModel

    var body: some View {
        TabView(selection: $app.settingsTab) {
            GeneralSettings(app: app).tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            ModelSettings(app: app).tabItem { Label("Models", systemImage: "cpu") }.tag(SettingsTab.models)
            InlineSettingsView(app: app).tabItem { Label("Inline", systemImage: "text.cursor") }.tag(SettingsTab.inline)
            MeetingSettingsView(app: app).tabItem { Label("Meeting", systemImage: "captions.bubble") }.tag(SettingsTab.meeting)
            GlossarySettingsView(app: app).tabItem { Label("Glossary", systemImage: "character.book.closed") }.tag(SettingsTab.glossary)
            AboutView(app: app).tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .padding(20)
        .frame(width: 620, height: 480)
    }
}

private struct GeneralSettings: View {
    let app: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var interfaceLanguage = (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first ?? ""
    @State private var languageChanged = false

    private static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Primary language", selection: $settings.primaryLanguage) {
                    ForEach(Language.all) { Text($0.localizedName).tag($0) }
                }
                Picker("Secondary language", selection: $settings.secondaryLanguage) {
                    ForEach(Language.all) { Text($0.localizedName).tag($0) }
                }
            } header: {
                Text("Language pair")
            } footer: {
                Text("Text in the primary language is translated into the secondary language; all other languages into the primary language.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use global shortcuts", isOn: $settings.hotkeysEnabled)
                LabeledContent("Translate selection") {
                    ShortcutRecorder(shortcut: $settings.translateShortcut,
                                     others: [settings.replaceShortcut, settings.rewriteShortcut],
                                     defaultValue: .defaultTranslate, onRecordingChange: app.setShortcutRecording)
                }
                LabeledContent("Translate and replace") {
                    ShortcutRecorder(shortcut: $settings.replaceShortcut,
                                     others: [settings.translateShortcut, settings.rewriteShortcut],
                                     defaultValue: .defaultReplace, onRecordingChange: app.setShortcutRecording)
                }
                LabeledContent("Improve writing and replace") {
                    ShortcutRecorder(shortcut: $settings.rewriteShortcut,
                                     others: [settings.translateShortcut, settings.replaceShortcut],
                                     defaultValue: nil, onRecordingChange: app.setShortcutRecording)
                }
                if !app.accessibilityTrusted {
                    HStack {
                        Label("Accessibility permission required", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Grant") { app.requestAccessibility() }
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("If a clipboard manager (e.g. Raycast) uses ⇧⌘C, choose another shortcut. In the translation popup, ⌘↩ also replaces.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: settings.translateShortcut) { app.applyShortcuts() }
            .onChange(of: settings.replaceShortcut) { app.applyShortcuts() }
            .onChange(of: settings.rewriteShortcut) { app.applyShortcuts() }

            Section("Translation") {
                Picker("Default form of address", selection: $settings.defaultFormality) {
                    ForEach(Formality.allCases) { Text($0.title).tag($0) }
                }
                Picker("Default writing style", selection: $settings.defaultRewriteStyle) {
                    ForEach(RewriteStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Save translation history", isOn: $settings.historyEnabled)
                if !app.history.entries.isEmpty {
                    HStack {
                        Text("\(app.history.entries.count) entries, only on this Mac").foregroundStyle(.secondary)
                        Spacer()
                        Button("Show history") { app.windows.showHistory() }
                        Button("Clear", role: .destructive) { app.history.clear() }
                    }
                }
            }

            Section("System") {
                Picker("Interface language", selection: $interfaceLanguage) {
                    Text("System default").tag("")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Türkçe").tag("tr")
                }
                .onChange(of: interfaceLanguage) { _, code in
                    // Per-app override of the macOS language order; takes effect on next launch.
                    if code.isEmpty {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set([code], forKey: "AppleLanguages")
                    }
                    languageChanged = true
                }
                if languageChanged {
                    HStack {
                        Text("Restart Polylocal to apply the new language.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart now", action: Self.relaunch)
                    }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let launchError { Text(launchError).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelSettings: View {
    let app: AppModel

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Translation engine", selection: $settings.engineKind) {
                    Text("Built-in (llama.cpp)").tag(EngineKind.builtIn)
                    Text("Ollama").tag(EngineKind.ollama)
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.engineKind) { app.applyEngine() }
                LabeledContent("Status", value: app.engine.status.message)
            }
            if settings.engineKind == .builtIn {
                Section {
                    ForEach(app.store.models(.translation)) { ModelRow(app: app, model: $0) }
                } header: {
                    Text("Models")
                } footer: {
                    Text("Models are downloaded to \(app.store.directory.path). Translation happens entirely on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Ollama") { OllamaSection(app: app) }
            }
        }
        .formStyle(.grouped)
        .task { await app.refreshOllama() }
    }
}

private struct AboutView: View {
    let app: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "character.bubble").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Polylocal").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? String(localized: "development"))")
                .foregroundStyle(.secondary)
            Text("Open-source, free and fully local translation.\nYour text never leaves this Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            if app.updater.isAvailable { UpdateSettings(updater: app.updater) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct UpdateSettings: View {
    @Bindable var updater: Updater

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
                Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloads)
                    .disabled(!updater.automaticallyChecks)
                Text(lastCheckText).font(.caption).foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    private var lastCheckText: String {
        guard let date = updater.lastCheck else { return String(localized: "Updates are checked once a day. Only the list of versions is downloaded from GitHub; no personal data is sent.") }
        return String(localized: "Last checked: \(date.formatted(date: .abbreviated, time: .shortened))")
    }
}
