import AppKit
import SwiftUI
import TranslaterCore

struct InlineSettingsView: View {
    let app: AppModel
    @State private var showAdd = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Satır içi çeviri önerileri", isOn: $settings.inlineEnabled)
                    .onChange(of: settings.inlineEnabled) { app.applyInlineRules() }
            } footer: {
                Text("Kural eklediğin uygulamada başka bir dilde yazınca, imlecin altında çeviri önerisi çıkar. \"Tamamla\" açıksa, kuralın dilinde yazarken cümlenin devamı önerilir. ⇥ kabul eder, Esc kapatır, ⌥⇥ gerçek bir sekme ekler. Yalnızca kural olan uygulamalardaki metin okunur.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if settings.inlineRules.isEmpty {
                    Text("Henüz kural yok.").foregroundStyle(.secondary)
                }
                ForEach($settings.inlineRules) { $rule in
                    RuleRow(rule: $rule) {
                        settings.inlineRules.removeAll { $0.id == rule.id }
                    }
                }
                Button("Kural ekle…", systemImage: "plus") { showAdd = true }
            } header: {
                Text("Kurallar")
            }
            .onChange(of: settings.inlineRules) { app.applyInlineRules() }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAdd) {
            AddRuleSheet(defaultTarget: settings.secondaryLanguage) { rule in
                settings.inlineRules.append(rule)
            }
        }
    }
}

private struct RuleRow: View {
    @Binding var rule: InlineRule
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $rule.isEnabled).labelsHidden().toggleStyle(.checkbox)
            AppIcon(bundleID: rule.bundleID)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.appName)
                Text(rule.domain ?? "Tüm uygulama").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Hedef", selection: $rule.target) {
                ForEach(Language.all) { Text($0.localizedName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if rule.target.hasFormality {
                FormalityPicker(formality: $rule.formality)
            }
            Toggle("Tamamla", isOn: $rule.completions)
                .toggleStyle(.checkbox)
                .help("Bu dilde yazarken cümlenin devamını öner")
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Kuralı sil")
        }
    }
}

private struct AddRuleSheet: View {
    let defaultTarget: Language
    let onAdd: (InlineRule) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var apps: [NSRunningApplication] = []
    @State private var bundleID = ""
    @State private var domain = ""
    @State private var target: Language?
    @State private var completions = false

    static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.dia", "app.zen-browser.zen",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kural ekle").font(.title3.weight(.semibold))
            Form {
                Picker("Uygulama", selection: $bundleID) {
                    Text("Seç…").tag("")
                    ForEach(apps, id: \.processIdentifier) { app in
                        Text(app.localizedName ?? app.bundleIdentifier ?? "?").tag(app.bundleIdentifier ?? "")
                    }
                }
                if Self.browsers.contains(bundleID) {
                    TextField("Site (isteğe bağlı)", text: $domain, prompt: Text("ör. slack.com"))
                }
                Picker("Bu uygulamada yazdığım dil", selection: Binding(
                    get: { target ?? defaultTarget }, set: { target = $0 })) {
                    ForEach(Language.all) { Text($0.localizedName).tag($0) }
                }
                Toggle("Bu dilde yazarken cümle tamamlama öner", isOn: $completions)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Vazgeç", role: .cancel) { dismiss() }
                Button("Ekle") {
                    let name = apps.first { $0.bundleIdentifier == bundleID }?.localizedName ?? bundleID
                    let site = domain.trimmingCharacters(in: .whitespaces)
                    onAdd(InlineRule(bundleID: bundleID, appName: name, domain: site.isEmpty ? nil : site,
                                     target: target ?? defaultTarget, completions: completions))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bundleID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                    && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        }
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: "app").frame(width: 22, height: 22)
        }
    }
}
