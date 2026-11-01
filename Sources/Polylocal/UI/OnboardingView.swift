import ModelManager
import SwiftUI
import PolylocalCore

/// First launch: permission → model → shortcuts.
struct OnboardingView: View {
    let app: AppModel
    let onFinish: () -> Void
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                switch step {
                case 0: welcome
                case 1: permission
                case 2: model
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Text("\(step + 1) / 4").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if step < 3 {
                    Button(step == 0 ? "Start" : "Continue") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Finish") {
                        app.settings.hasCompletedOnboarding = true
                        onFinish()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 560, height: 460)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "character.bubble").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Welcome to Polylocal").font(.largeTitle.weight(.semibold))
            Text("Translates in any app with a shortcut, entirely on this Mac. Your text is never sent to a server.")
                .font(.title3).foregroundStyle(.secondary)
            Spacer()
            Label("Press ⌘C twice to translate the selected text", systemImage: "command")
            Label("Press ⇧⌘C twice to translate what you wrote and replace it", systemImage: "arrow.uturn.left")
            Text("You can change the shortcuts in Settings.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accessibility permission").font(.title.weight(.semibold))
            Text("Needed to detect the shortcuts, read the selected text and write the translation back. Polylocal uses it only when you press a shortcut and never touches password fields.")
                .foregroundStyle(.secondary)
            Spacer().frame(height: 8)
            if app.accessibilityTrusted {
                Label("Permission granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            } else {
                Button("Grant in System Settings") { app.requestAccessibility() }
                    .controlSize(.large)
                Text("Turn on Polylocal in Privacy & Security → Accessibility. This screen notices the change automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var model: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Translation model").font(.title.weight(.semibold))
            Text("Translations are done by an AI model downloaded to this Mac. This Mac has \(Hardware.memoryGB) GB of memory.")
                .foregroundStyle(.secondary)
            if let models = app.ollamaModels, !models.isEmpty {
                GroupBox {
                    VStack(alignment: .leading) {
                        Text("Ollama is installed: you can use an existing model without downloading.").font(.callout)
                        OllamaSection(app: app)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(app.store.models(.translation).filter { $0.minRAMGB <= max(Hardware.memoryGB, 8) }) {
                        ModelRow(app: app, model: $0)
                        Divider()
                    }
                }
            }
            Text(app.engine.status.message).font(.caption).foregroundStyle(.secondary)
        }
        .task { await app.refreshOllama() }
        .onChange(of: app.store.installedModels(.translation).map(\.id)) { _, installed in
            // Use a freshly downloaded model right away if nothing is configured yet.
            if !app.engine.status.isReady, let first = installed.first {
                app.settings.engineKind = .builtIn
                app.settings.builtInModelID = app.settings.builtInModelID.flatMap { installed.contains($0) ? $0 : nil } ?? first
                app.applyEngine()
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You're all set").font(.title.weight(.semibold))
            Text("Polylocal runs in the menu bar.").foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text(app.settings.translateShortcut?.displayString ?? "—").monospaced().bold()
                    Text("Translate selection")
                }
                GridRow {
                    Text(app.settings.replaceShortcut?.displayString ?? "—").monospaced().bold()
                    Text("Translate and replace (↩ after the preview)")
                }
                GridRow { Text("Esc").monospaced().bold(); Text("Close the translation popup") }
            }
            Spacer()
            Text(app.engine.status.message).font(.caption).foregroundStyle(.secondary)
        }
    }
}
