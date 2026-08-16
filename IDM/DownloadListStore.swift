//
//  DownloadListStore.swift
//  IDM
//
//  Bridges the IDMEngine actor's AsyncStream-based API to SwiftUI: owns the
//  DownloadEngine, keeps an observable snapshot of every task, forwards user
//  actions (add/pause/resume/cancel/retry) onto the engine, and persists the
//  list so it survives relaunch.

import Foundation
import Observation
import IDMCore
import IDMEngine

@MainActor
@Observable
final class DownloadListStore {
    private(set) var tasks: [DownloadTask] = []
    private(set) var lastErrorMessage: String?

    private let engine: DownloadEngine
    private let store: TaskStore
    private var watchers: [UUID: Task<Void, Never>] = [:]

    init(engine: DownloadEngine = DownloadEngine(), store: TaskStore = TaskStore()) {
        self.engine = engine
        self.store = store
    }

    /// Re-seeds the engine with whatever was persisted from the previous
    /// launch. Call once, e.g. from ContentView's `.task`. Mid-flight
    /// downloads come back `.paused` (see DownloadEngine.restore) — the user
    /// resumes them explicitly rather than data silently starting to flow
    /// again on launch.
    func restorePersistedTasks() async {
        let persisted = store.load()
        guard !persisted.isEmpty else { return }

        for task in persisted {
            await engine.restore(task)
            if let restored = await engine.task(for: task.id) {
                tasks.append(restored)
            }
            watch(task.id)
        }
        tasks.sort { $0.createdAt > $1.createdAt }
    }

    func addDownload(url: URL) async {
        let destination = Self.downloadsDirectory.appendingPathComponent(uniqueFileName(for: url))

        do {
            let id = try await engine.start(url: url, destination: destination)
            if let task = await engine.task(for: id) {
                tasks.insert(task, at: 0)
            }
            watch(id)
            persistSoon()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func pause(_ id: UUID) async {
        await engine.pause(taskId: id)
    }

    func resume(_ id: UUID) async {
        await engine.resume(taskId: id)
    }

    func cancel(_ id: UUID) async {
        await engine.cancel(taskId: id)
    }

    /// Cleanly pauses every actively-downloading task. Used when the app is
    /// about to background: a clean pause preserves exact per-chunk byte
    /// offsets for resume, whereas letting the process get suspended
    /// mid-write would not.
    func pauseAllActiveDownloads() async {
        for task in tasks where task.state == .downloading {
            await engine.pause(taskId: task.id)
        }
    }

    /// There's no in-place retry on the engine yet — a failed/cancelled task's
    /// destination and chunk state are gone, so retry just re-enqueues the
    /// same URL as a fresh task.
    func retry(_ id: UUID) async {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        tasks.removeAll { $0.id == id }
        watchers[id]?.cancel()
        watchers[id] = nil
        await addDownload(url: task.remoteURL)
    }

    /// Grabs a fully accurate snapshot — including live per-chunk byte
    /// offsets, which `tasks` doesn't otherwise carry (see
    /// DownloadEngine.snapshotAllChunks) — and writes it to disk. Called when
    /// the app is about to background/terminate, since that's the moment an
    /// accurate mid-chunk resume point actually matters; routine progress
    /// updates persist opportunistically on state changes but don't pay for
    /// a full chunk snapshot on every byte delta.
    func persistNow() async {
        await engine.snapshotAllChunks()
        tasks = await engine.allTasks().sorted { $0.createdAt > $1.createdAt }
        store.save(tasks)
    }

    private func watch(_ id: UUID) {
        watchers[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.engine.progressStream(for: id)
            for await update in stream {
                self.apply(update)
            }
        }
    }

    private func apply(_ update: ProgressUpdate) {
        guard let index = tasks.firstIndex(where: { $0.id == update.taskId }) else { return }
        let previousState = tasks[index].state
        tasks[index].downloadedBytes = update.downloadedBytes
        tasks[index].totalBytes = update.totalBytes
        tasks[index].state = update.state
        tasks[index].updatedAt = Date()

        if update.state != previousState {
            persistSoon()
        }
    }

    /// Lightweight persistence for state-change bookkeeping — saves whatever
    /// `tasks` currently holds. This does NOT carry accurate per-chunk byte
    /// offsets (that's what `persistNow()` is for); it's enough to survive a
    /// relaunch and know a task existed and roughly where it stood.
    private func persistSoon() {
        store.save(tasks)
    }

    private func uniqueFileName(for url: URL) -> String {
        let base = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        return "\(UUID().uuidString.prefix(8))-\(base)"
    }

    private static var downloadsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
