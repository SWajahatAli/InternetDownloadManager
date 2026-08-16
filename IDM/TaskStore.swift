//
//  TaskStore.swift
//  IDM
//
//  Persists the download list to a JSON file so it survives app relaunch.
//  Deliberately simple (whole-list read/write, no incremental diffing) — the
//  list is expected to stay small (tens of entries), not worth a database for.

import Foundation
import IDMCore

struct TaskStore {
    private let fileURL: URL

    /// `directory` is injectable so tests can point this at a scratch
    /// location instead of the real app's Application Support folder.
    init(directory: URL? = nil) {
        let baseDir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IDM", isDirectory: true)
        if !FileManager.default.fileExists(atPath: baseDir.path) {
            try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        }
        fileURL = baseDir.appendingPathComponent("downloads.json")
    }

    func load() -> [DownloadTask] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([DownloadTask].self, from: data)) ?? []
    }

    func save(_ tasks: [DownloadTask]) {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
