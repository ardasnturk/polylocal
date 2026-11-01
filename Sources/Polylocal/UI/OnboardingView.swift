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
                if step > 0 { Button("Geri") { step -= 1 } }
                Spacer()
                Text("\(step + 1) / 4").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if step < 3 {
                    Button(step == 0 ? "Başla" : "Devam") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Bitir") {
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
            Text("Polylocal'a hoş geldin").font(.largeTitle.weight(.semibold))
            Text("Her uygulamada, kısayolla, tamamen bu Mac üzerinde çeviri yapar. Metinlerin hiçbir sunucuya gönderilmez.")
                .font(.title3).foregroundStyle(.secondary)
            Spacer()
            Label("Seçili metni çevirmek için ⌘C'ye iki kez bas", systemImage: "command")
            Label("Yazdığını çevirip yerine yazmak için ⌘⇧C'ye iki kez bas", systemImage: "arrow.uturn.left")
            Text("Kısayolları Ayarlar'dan değiştirebilirsin.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Erişilebilirlik izni").font(.title.weight(.semibold))
            Text("Kısayolları algılamak, seçili metni okumak ve çeviriyi yerine yazmak için gerekli. Polylocal bu izni yalnızca sen kısayola bastığında kullanır; şifre alanlarına asla dokunmaz.")
                .foregroundStyle(.secondary)
            Spacer().frame(height: 8)
            if app.accessibilityTrusted {
                Label("İzin verildi", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            } else {
                Button("Sistem Ayarları'nda izin ver") { app.requestAccessibility() }
                    .controlSize(.large)
                Text("Gizlilik ve Güvenlik → Erişilebilirlik listesinde Polylocal'ı aç. Bu ekran izni otomatik algılar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var model: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Çeviri modeli").font(.title.weight(.semibold))
            Text("Çeviriler bu Mac'e indirilen bir AI modeliyle yapılır. Bu Mac'te \(Hardware.memoryGB) GB bellek var.")
                .foregroundStyle(.secondary)
            if let models = app.ollamaModels, !models.isEmpty {
                GroupBox {
                    VStack(alignment: .leading) {
                        Text("Ollama kurulu: mevcut bir modeli indirmeden kullanabilirsin.").font(.callout)
                        OllamaSection(app: app)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(app.store.catalog.filter { $0.minRAMGB <= max(Hardware.memoryGB, 8) }) {
                        ModelRow(app: app, model: $0)
                        Divider()
                    }
                }
            }
            Text(app.engine.status.message).font(.caption).foregroundStyle(.secondary)
        }
        .task { await app.refreshOllama() }
        .onChange(of: app.store.installedModels.map(\.id)) { _, installed in
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
            Text("Hazırsın").font(.title.weight(.semibold))
            Text("Polylocal menü çubuğunda çalışır.").foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text(app.settings.translateShortcut?.displayString ?? "—").monospaced().bold()
                    Text("Seçili metni çevir")
                }
                GridRow {
                    Text(app.settings.replaceShortcut?.displayString ?? "—").monospaced().bold()
                    Text("Çevir ve yerine yaz (önizlemeden sonra ↩)")
                }
                GridRow { Text("Esc").monospaced().bold(); Text("Çeviri penceresini kapat") }
            }
            Spacer()
            Text(app.engine.status.message).font(.caption).foregroundStyle(.secondary)
        }
    }
}
