import ServiceManagement
import SwiftUI
import TranslaterCore

struct SettingsView: View {
    let app: AppModel

    var body: some View {
        TabView {
            GeneralSettings(app: app).tabItem { Label("Genel", systemImage: "gearshape") }
            ModelSettings(app: app).tabItem { Label("Modeller", systemImage: "cpu") }
            InlineSettingsView(app: app).tabItem { Label("Satır içi", systemImage: "text.cursor") }
            AboutView().tabItem { Label("Hakkında", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(width: 620, height: 480)
    }
}

private struct GeneralSettings: View {
    let app: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Ana dil", selection: $settings.primaryLanguage) {
                    ForEach(Language.all) { Text($0.localizedName).tag($0) }
                }
                Picker("İkinci dil", selection: $settings.secondaryLanguage) {
                    ForEach(Language.all) { Text($0.localizedName).tag($0) }
                }
            } header: {
                Text("Dil çifti")
            } footer: {
                Text("Ana dildeki metin ikinci dile, diğer tüm diller ana dile çevrilir.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Global kısayolları kullan", isOn: $settings.hotkeysEnabled)
                LabeledContent("Seçili metni çevir") {
                    ShortcutRecorder(shortcut: $settings.translateShortcut, other: settings.replaceShortcut,
                                     defaultValue: .defaultTranslate, onRecordingChange: app.setShortcutRecording)
                }
                LabeledContent("Çevir ve yerine yaz") {
                    ShortcutRecorder(shortcut: $settings.replaceShortcut, other: settings.translateShortcut,
                                     defaultValue: .defaultReplace, onRecordingChange: app.setShortcutRecording)
                }
                if !app.accessibilityTrusted {
                    HStack {
                        Label("Erişilebilirlik izni gerekli", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("İzin ver") { app.requestAccessibility() }
                    }
                }
            } header: {
                Text("Kısayollar")
            } footer: {
                Text("⇧⌘C bir pano yöneticisi (ör. Raycast) tarafından kullanılıyorsa başka bir kısayol seç. Çeviri penceresinde ⌘↩ da yerine yazar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: settings.translateShortcut) { app.applyShortcuts() }
            .onChange(of: settings.replaceShortcut) { app.applyShortcuts() }

            Section("Çeviri") {
                Picker("Varsayılan hitap", selection: $settings.defaultFormality) {
                    ForEach(Formality.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Çeviri geçmişini kaydet", isOn: $settings.historyEnabled)
                if !app.history.entries.isEmpty {
                    HStack {
                        Text("\(app.history.entries.count) kayıt, yalnızca bu Mac'te").foregroundStyle(.secondary)
                        Spacer()
                        Button("Geçmişi göster") { app.windows.showHistory() }
                        Button("Temizle", role: .destructive) { app.history.clear() }
                    }
                }
            }

            Section("Sistem") {
                Toggle("Girişte başlat", isOn: $launchAtLogin)
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
                Picker("Çeviri motoru", selection: $settings.engineKind) {
                    Text("Yerleşik (llama.cpp)").tag(EngineKind.builtIn)
                    Text("Ollama").tag(EngineKind.ollama)
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.engineKind) { app.applyEngine() }
                LabeledContent("Durum", value: app.engine.status.message)
            }
            if settings.engineKind == .builtIn {
                Section {
                    ForEach(app.store.catalog) { ModelRow(app: app, model: $0) }
                } header: {
                    Text("Modeller")
                } footer: {
                    Text("Modeller \(app.store.directory.path) klasörüne indirilir. Çeviriler tamamen bu Mac'te yapılır.")
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
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "character.bubble").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Translater").font(.title2.weight(.semibold))
            Text("Sürüm \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "geliştirme")")
                .foregroundStyle(.secondary)
            Text("Açık kaynak, ücretsiz ve tamamen yerel çeviri.\nMetinlerin bu Mac'ten hiç çıkmaz.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
