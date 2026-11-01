import ServiceManagement
import SwiftUI
import TranslaterCore

struct SettingsView: View {
    let app: AppModel

    var body: some View {
        TabView {
            GeneralSettings(app: app).tabItem { Label("Genel", systemImage: "gearshape") }
            ModelSettings(app: app).tabItem { Label("Modeller", systemImage: "cpu") }
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

            Section("Kısayollar") {
                Toggle("Global kısayolları kullan", isOn: $settings.hotkeysEnabled)
                LabeledContent("Seçili metni çevir", value: "⌘C C")
                LabeledContent("Çevir ve yerine yaz", value: "⌘⇧C C")
                if !app.accessibilityTrusted {
                    HStack {
                        Label("Erişilebilirlik izni gerekli", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("İzin ver") { app.requestAccessibility() }
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
