//
//  DownloadRowView.swift
//  IDM
//

import SwiftUI
import IDMCore

struct DownloadRowView: View {
    let task: DownloadTask
    var store: DownloadListStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.destinationURL.lastPathComponent)
                .font(.headline)
                .lineLimit(1)

            switch task.state {
            case .downloading, .paused:
                ProgressView(value: task.fractionCompleted)
                HStack {
                    Text("\(byteString(task.downloadedBytes)) / \(task.totalBytes.map(byteString) ?? "?")")
                    Spacer()
                    Text(task.state == .paused ? "Paused" : "\(Int(task.fractionCompleted * 100))%")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            default:
                HStack {
                    Text(label(for: task.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if case .failed(let error) = task.state {
                        Text(message(for: error))
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }

            HStack(spacing: 16) {
                switch task.state {
                case .downloading:
                    Button("Pause") { Task { await store.pause(task.id) } }
                case .paused:
                    Button("Resume") { Task { await store.resume(task.id) } }
                case .failed, .cancelled:
                    Button("Retry") { Task { await store.retry(task.id) } }
                case .queued, .validating, .completed:
                    EmptyView()
                }

                if task.state == .downloading || task.state == .paused {
                    Button("Cancel", role: .destructive) { Task { await store.cancel(task.id) } }
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func label(for state: DownloadState) -> String {
        switch state {
        case .queued: return "Queued"
        case .validating: return "Validating"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private func message(for error: DownloadError) -> String {
        switch error {
        case .invalidResponse: return "Invalid server response"
        case .serverRejectedRangeRequest: return "Server rejected range request"
        case .unresolvableContentLength: return "Unknown file size"
        case .fileSystemFailure(let message): return message
        case .networkFailure(let message): return message
        case .chunkExceededRetryLimit: return "Download failed after retries"
        case .cancelled: return "Cancelled"
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
