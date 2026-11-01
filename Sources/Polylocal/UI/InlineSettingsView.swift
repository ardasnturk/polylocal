import AppKit
import SwiftUI
import PolylocalCore

struct InlineSettingsView: View {
    let app: AppModel
    @State private var showAdd = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Inline translation suggestions", isOn: $settings.inlineEnabled)
                    .onChange(of: settings.inlineEnabled) { app.applyInlineRules() }
            } footer: {
                Text("When you type in another language in an app with a rule, a translation suggestion appears below the caret. If \"Complete\" is on, the rest of the sentence is suggested while you write in the rule's language. ⇥ accepts, Esc dismisses, ⌥⇥ inserts a real tab. Text is read only in apps that have a rule.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if settings.inlineRules.isEmpty {
                    Text("No rules yet.").foregroundStyle(.secondary)
                }
                ForEach($settings.inlineRules) { $rule in
                    RuleRow(rule: $rule) {
                        settings.inlineRules.removeAll { $0.id == rule.id }
                    }
                }
                Button("Add rule…", systemImage: "plus") { showAdd = true }
            } header: {
                Text("Rules")
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
                Text(rule.domain ?? String(localized: "Whole app")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Target", selection: $rule.target) {
                ForEach(Language.all) { Text($0.localizedName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if rule.target.hasFormality {
                FormalityPicker(formality: $rule.formality)
            }
            Toggle("Complete", isOn: $rule.completions)
                .toggleStyle(.checkbox)
                .help("Suggest the rest of the sentence while writing in this language")
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete rule")
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
            Text("Add rule").font(.title3.weight(.semibold))
            Form {
                Picker("App", selection: $bundleID) {
                    Text("Choose…").tag("")
                    ForEach(apps, id: \.processIdentifier) { app in
                        Text(app.localizedName ?? app.bundleIdentifier ?? "?").tag(app.bundleIdentifier ?? "")
                    }
                }
                if Self.browsers.contains(bundleID) {
                    TextField("Site (optional)", text: $domain, prompt: Text("e.g. slack.com"))
                }
                Picker("Language I write in this app", selection: Binding(
                    get: { target ?? defaultTarget }, set: { target = $0 })) {
                    ForEach(Language.all) { Text($0.localizedName).tag($0) }
                }
                Toggle("Suggest sentence completions while writing in this language", isOn: $completions)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
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
