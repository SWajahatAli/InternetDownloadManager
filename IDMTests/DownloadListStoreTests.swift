//
//  DownloadListStoreTests.swift
//  IDMTests
//

import Testing
import Foundation
import IDMCore
import IDMEngine
@testable import IDM

// .serialized: MockURLProtocol.handler is process-wide shared mutable state
// (URLProtocol registration is class-based, not instance-based), so tests
// that each set a different handler cannot safely run in parallel — Swift
// Testing parallelizes by default and would otherwise let one test's handler
// clobber another's mid-download.
@MainActor
@Suite("DownloadListStore", .serialized)
struct DownloadListStoreTests {
    private func makeStore(chunkSizeBytes: Int64 = 1024) -> (DownloadListStore, URL) {
        let session = MockURLProtocol.makeSession()
        let engine = DownloadEngine(
            validator: ResourceValidator(session: session),
            session: session,
            chunkSizeBytes: chunkSizeBytes,
            maxConcurrentChunksPerTask: 2
        )
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let store = DownloadListStore(engine: engine, store: TaskStore(directory: tempDir))
        return (store, tempDir)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition not met within \(timeout)s")
    }

    private func stubRangedDownload(payload: Data) {
        MockURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Accept-Ranges": "bytes", "Content-Length": "\(payload.count)"]
                )!
                return (response, Data())
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: nil)!
            return (response, payload)
        }
    }

    @Test
    func addDownload_appendsTaskAndReachesCompleted() async throws {
        stubRangedDownload(payload: Data("hello world".utf8))
        let (store, _) = makeStore()

        await store.addDownload(url: URL(string: "https://example.com/hello.txt")!)
        #expect(store.tasks.count == 1)

        try await waitUntil { store.tasks.first?.state == .completed }
    }

    @Test
    func cancel_marksTaskCancelled_butKeepsItInTheList() async throws {
        MockURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Accept-Ranges": "bytes", "Content-Length": "4"]
                )!
                return (response, Data())
            }
            Thread.sleep(forTimeInterval: 0.2) // keep the GET open so cancel() beats it
            throw URLError(.timedOut)
        }
        let (store, _) = makeStore()

        await store.addDownload(url: URL(string: "https://example.com/slow.bin")!)
        guard let id = store.tasks.first?.id else {
            Issue.record("expected a task to have been added")
            return
        }

        try await waitUntil { store.tasks.first?.state == .downloading }
        await store.cancel(id)

        #expect(store.tasks.count == 1, "cancel should not remove the task, just mark it")
        #expect(store.tasks.first?.state == .cancelled)
    }

    @Test
    func retry_removesOldTaskAndEnqueuesFreshOneForTheSameURL() async throws {
        stubRangedDownload(payload: Data("retry me".utf8))
        let (store, _) = makeStore()

        let url = URL(string: "https://example.com/retry.txt")!
        await store.addDownload(url: url)
        guard let originalId = store.tasks.first?.id else {
            Issue.record("expected a task to have been added")
            return
        }
        try await waitUntil { store.tasks.first?.state == .completed }

        await store.retry(originalId)

        #expect(store.tasks.count == 1)
        #expect(store.tasks.first?.id != originalId)
        #expect(store.tasks.first?.remoteURL == url)
    }

    @Test
    func persistNow_writesTasksToTaskStore() async throws {
        stubRangedDownload(payload: Data("persisted".utf8))
        let (store, tempDir) = makeStore()

        await store.addDownload(url: URL(string: "https://example.com/persisted.txt")!)
        try await waitUntil { store.tasks.first?.state == .completed }

        await store.persistNow()

        let reloaded = TaskStore(directory: tempDir).load()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.state == .completed)
    }

    @Test
    func restorePersistedTasks_reappearsInTheList() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let taskStore = TaskStore(directory: tempDir)

        let persisted = DownloadTask(
            remoteURL: URL(string: "https://example.com/old.txt")!,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent("old.txt"),
            state: .completed,
            totalBytes: 100,
            downloadedBytes: 100
        )
        taskStore.save([persisted])

        let session = MockURLProtocol.makeSession()
        let engine = DownloadEngine(session: session)
        let store = DownloadListStore(engine: engine, store: taskStore)

        await store.restorePersistedTasks()

        #expect(store.tasks.count == 1)
        #expect(store.tasks.first?.id == persisted.id)
        #expect(store.tasks.first?.state == .completed)
    }
}
