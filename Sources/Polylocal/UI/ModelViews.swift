import ModelManager
import SwiftUI
import PolylocalCore

/// One catalog model with its download state and actions. Used in Settings and onboarding.
struct ModelRow: View {
    let app: AppModel
    let model: CatalogModel
    @State private var showLicense = false

    private var state: ModelStore.State { app.store.state(of: model) }
    /// A speech model has nothing to choose between: in use once installed.
    private var isSelected: Bool {
        switch model.kind {
        case .translation: app.settings.engineKind == .builtIn && app.settings.builtInModelID == model.id
        case .speech: state == .installed
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name).fontWeight(.medium)
                    if model.id == recommendedID {
                        Text("Recommended").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                Text(LocalizedStringKey(model.summary)).font(.caption).foregroundStyle(.secondary)
                Text("\(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)) · at least \(model.minRAMGB) GB RAM · \(model.license.name)")
                    .font(.caption2).foregroundStyle(.tertiary)
                if case .downloading(let progress, let received) = state {
                    ProgressView(value: progress)
                    Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if case .failed(let message) = state {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            actions
        }
        .padding(.vertical, 4)
        .alert("\(model.license.name)", isPresented: $showLicense) {
            Button("Accept and download") { app.store.download(model) }
            Button("Open license") { NSWorkspace.shared.open(model.license.url) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.name) is subject to its own license terms. By downloading it, you accept them.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .notInstalled, .failed:
            Button("Download") {
                if model.license.requiresAcceptance { showLicense = true } else { app.store.download(model) }
            }
        case .downloading:
            Button("Stop") { app.store.cancel(model) }
        case .verifying:
            ProgressView().controlSize(.small)
        case .installed:
            HStack {
                if !isSelected {
                    Button("Use") {
                        app.settings.engineKind = .builtIn
                        app.settings.builtInModelID = model.id
                        app.applyEngine()
                    }
                }
                Menu {
                    Button("Delete", role: .destructive) {
                        if model.kind == .speech { app.meeting.stop() }
                        let wasSelected = isSelected
                        app.store.delete(model)
                        if wasSelected, model.kind == .translation { app.applyEngine() }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
        }
    }

    private var recommendedID: String? {
        CatalogModel.recommended(from: app.store.catalog, ramGB: Hardware.memoryGB)?.id
    }
}

/// Picker for models the user already has in Ollama.
struct OllamaSection: View {
    let app: AppModel

    var body: some View {
        if let models = app.ollamaModels {
            if models.isEmpty {
                Text("Ollama is running but has no models installed.").foregroundStyle(.secondary)
            } else {
                Picker("Ollama model", selection: Binding(
                    get: { app.settings.ollamaModel ?? "" },
                    set: { name in
                        app.settings.ollamaModel = name
                        app.settings.engineKind = .ollama
                        app.applyEngine()
                    })) {
                    if app.settings.ollamaModel == nil { Text("Choose…").tag("") }
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
        } else {
            HStack {
                Text("Ollama not found (localhost:11434).").foregroundStyle(.secondary)
                Button("Try again") { Task { await app.refreshOllama() } }
            }
        }
    }
}
