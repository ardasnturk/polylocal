import CryptoKit
import Foundation
import Observation
import PolylocalCore

/// Owns the model catalog and the models on disk: download with progress, SHA-256 check, delete.
@MainActor
@Observable
public final class ModelStore {
    public enum State: Equatable, Sendable {
        case notInstalled
        case downloading(progress: Double, receivedBytes: Int64)
        case verifying
        case installed
        case failed(String)
    }

    public private(set) var catalog: [CatalogModel]
    public private(set) var states: [CatalogModel.ID: State] = [:]

    public let directory: URL
    private var tasks: [CatalogModel.ID: Task<Void, Never>] = [:]

    public init(catalog: [CatalogModel], directory: URL = ModelStore.defaultDirectory) {
        self.catalog = catalog
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        refresh()
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Polylocal/Models", isDirectory: true)
    }

    public func state(of model: CatalogModel) -> State {
        states[model.id] ?? .notInstalled
    }

    public func fileURL(for model: CatalogModel) -> URL {
        directory.appendingPathComponent(model.fileName)
    }

    public var installedModels: [CatalogModel] {
        catalog.filter { state(of: $0) == .installed }
    }

    public func models(_ kind: CatalogModel.Kind) -> [CatalogModel] {
        catalog.filter { $0.kind == kind }
    }

    public func installedModels(_ kind: CatalogModel.Kind) -> [CatalogModel] {
        installedModels.filter { $0.kind == kind }
    }

    /// A file counts as installed once it passed verification; the `.verified` marker avoids re-hashing GBs on launch.
    public func refresh() {
        for model in catalog where tasks[model.id] == nil {
            let fm = FileManager.default
            let installed = fm.fileExists(atPath: fileURL(for: model).path)
                && fm.fileExists(atPath: markerURL(for: model).path)
            states[model.id] = installed ? .installed : .notInstalled
        }
    }

    public func download(_ model: CatalogModel) {
        guard tasks[model.id] == nil else { return }
        states[model.id] = .downloading(progress: 0, receivedBytes: 0)
        tasks[model.id] = Task { [weak self] in
            await self?.runDownload(model)
        }
    }

    public func cancel(_ model: CatalogModel) {
        tasks[model.id]?.cancel()
    }

    public func delete(_ model: CatalogModel) {
        cancel(model)
        try? FileManager.default.removeItem(at: fileURL(for: model))
        try? FileManager.default.removeItem(at: markerURL(for: model))
        states[model.id] = .notInstalled
    }

    private func runDownload(_ model: CatalogModel) async {
        defer { tasks[model.id] = nil }
        let destination = fileURL(for: model)
        do {
            let temp = try await Downloader.download(model.url, expectedBytes: model.sizeBytes) { [weak self] received in
                Task { @MainActor in
                    guard let self, case .downloading = self.state(of: model) else { return }
                    let progress = model.sizeBytes > 0 ? Double(received) / Double(model.sizeBytes) : 0
                    self.states[model.id] = .downloading(progress: min(progress, 1), receivedBytes: received)
                }
            }
            states[model.id] = .verifying
            let digest = try await Task.detached(priority: .utility) { try Self.sha256(of: temp) }.value
            guard digest == model.sha256.lowercased() else {
                try? FileManager.default.removeItem(at: temp)
                states[model.id] = .failed(String(localized: "Could not verify the file (SHA-256 mismatch)."))
                return
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
            try Data(digest.utf8).write(to: markerURL(for: model))
            states[model.id] = .installed
        } catch is CancellationError {
            states[model.id] = .notInstalled
        } catch let error as URLError where error.code == .cancelled {
            states[model.id] = .notInstalled
        } catch {
            states[model.id] = .failed(error.localizedDescription)
        }
    }

    private func markerURL(for model: CatalogModel) -> URL {
        directory.appendingPathComponent(model.fileName + ".verified")
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension ModelStore {
    /// Loads the catalog shipped in the app bundle, falling back to the repo copy during `swift run`.
    public static func bundledCatalog() -> [CatalogModel] {
        var candidates: [URL] = []
        if let url = Bundle.main.url(forResource: "catalog", withExtension: "json") { candidates.append(url) }
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repoRoot.appendingPathComponent("models/catalog.json"))
        for url in candidates {
            if let data = try? Data(contentsOf: url), let catalog = try? ModelCatalog.decode(data) {
                return catalog.models
            }
        }
        return []
    }
}

/// URLSession download with byte-level progress, bridged to async/await with cancellation.
enum Downloader {
    static func download(_ url: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Int64) -> Void
        var continuation: CheckedContinuation<URL, Error>?
        private var lastReport = Date.distantPast

        init(progress: @escaping @Sendable (Int64) -> Void) {
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            // Throttle UI updates to ~10/s.
            guard Date().timeIntervalSince(lastReport) > 0.1 else { return }
            lastReport = Date()
            progress(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                resume(.failure(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])))
                return
            }
            // The system deletes `location` when this method returns, so move it first.
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".part")
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                resume(.success(kept))
            } catch {
                resume(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { resume(.failure(error)) }
        }

        private func resume(_ result: Result<URL, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}
