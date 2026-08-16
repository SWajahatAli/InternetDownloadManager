//
//  TaskStoreTests.swift
//  IDMTests
//

import Testing
import Foundation
import IDMCore
@testable import IDM

@Suite("TaskStore")
struct TaskStoreTests {
    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test
    func load_returnsEmptyArray_whenNoFileExistsYet() {
        let store = TaskStore(directory: makeTempDirectory())
        #expect(store.load().isEmpty)
    }

    @Test
    func save_thenLoad_roundTripsExactly() {
        let store = TaskStore(directory: makeTempDirectory())
        let tasks = [
            DownloadTask(
                remoteURL: URL(string: "https://example.com/a.zip")!,
                destinationURL: URL(fileURLWithPath: "/tmp/a.zip"),
                state: .completed,
                totalBytes: 500,
                downloadedBytes: 500
            ),
            DownloadTask(
                remoteURL: URL(string: "https://example.com/b.zip")!,
                destinationURL: URL(fileURLWithPath: "/tmp/b.zip"),
                state: .failed(.networkFailure("timed out")),
                totalBytes: 200,
                downloadedBytes: 50,
                chunks: [
                    Chunk(id: 0, range: 0...99, downloadedBytes: 50, state: .failed(retryCount: 3)),
                    Chunk(id: 1, range: 100...199, downloadedBytes: 0, state: .pending)
                ],
                supportsRangeRequests: true
            )
        ]

        store.save(tasks)
        let reloaded = store.load()

        #expect(reloaded == tasks)
    }

    @Test
    func save_overwritesPreviousContents() {
        let store = TaskStore(directory: makeTempDirectory())
        let first = DownloadTask(remoteURL: URL(string: "https://example.com/a.zip")!, destinationURL: URL(fileURLWithPath: "/tmp/a.zip"))
        let second = DownloadTask(remoteURL: URL(string: "https://example.com/b.zip")!, destinationURL: URL(fileURLWithPath: "/tmp/b.zip"))

        store.save([first])
        store.save([second])

        let reloaded = store.load()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.id == second.id)
    }
}
