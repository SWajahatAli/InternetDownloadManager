//
//  BackgroundTaskCoordinator.swift
//  IDM
//
//  IMPORTANT SCOPE NOTE: this is NOT the same thing as a background
//  URLSession — it does not let downloads continue indefinitely while the
//  app is suspended. iOS only grants a background URLSession real, extended
//  network access while suspended, and that API is delegate-based
//  (URLSessionDownloadTask), fundamentally incompatible with ChunkWorker's
//  async `bytes(for:)` streaming used to drive concurrent byte-range fetches
//  here. Rebuilding ChunkWorker on URLSessionDownloadTask + delegate + an
//  `application(_:handleEventsForBackgroundURLSession:)` relaunch hook would
//  be a substantial, different networking model — intentionally out of
//  scope for this pass.
//
//  What this DOES do: beginBackgroundTask grants a short grace period
//  (historically ~30s, not guaranteed) after the app backgrounds, before
//  the process is suspended. We use it to pause active downloads cleanly
//  (preserving exact per-chunk byte offsets) and persist that state, so a
//  relaunch resumes from the right place instead of from whatever the
//  process happened to be doing when suspended.

import UIKit

@MainActor
final class BackgroundTaskCoordinator {
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Starts the grace period and runs `work` inside it, ending the task
    /// when `work` finishes. If the OS's expiration handler fires first
    /// (grace period about to run out), the background task is ended
    /// immediately regardless of whether `work` has finished — there's no
    /// more time to ask for.
    func run(_ work: @escaping () async -> Void) {
        guard backgroundTaskID == .invalid else { return }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "IDM.pauseAndPersist") { [weak self] in
            self?.end()
        }

        guard backgroundTaskID != .invalid else { return } // no time was granted at all

        Task { [weak self] in
            await work()
            self?.end()
        }
    }

    func end() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
