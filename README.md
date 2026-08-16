# IDM — Internet Download Manager for iOS

A native iOS download manager built on **Swift Concurrency** — actor-isolated state, structured/unstructured task coordination, `AsyncStream`-based live progress, no GCD, no Combine, no third-party networking libraries.

The app splits large downloads into concurrent byte-range chunks, streams each chunk straight to disk, supports pause/resume/cancel/retry, survives app relaunch, and takes explicit, documented positions on the platform tradeoffs that come with all of that on iOS (see [Known Limitations](#known-limitations)).

## Architecture

The project is split across two repositories:

```
InternetDownloadManager/          (this repo — the app)
├── IDM/
│   ├── IDMApp.swift               App entry point, scene-phase → background-task wiring
│   ├── ContentView.swift          Download list UI
│   ├── DownloadListStore.swift    @Observable bridge between SwiftUI and the engine
│   ├── TaskStore.swift            JSON persistence for the download list
│   ├── BackgroundTaskCoordinator.swift   UIApplication background-task grace period
│   └── Views/
│       ├── AddDownloadView.swift  URL entry sheet
│       └── DownloadRowView.swift  Per-download row (progress, pause/resume/cancel/retry)
└── IDMTests/                      DownloadListStore + TaskStore tests

IDMCore/                          (sibling repo — the engine, github.com/SWajahatAli/IDMCore)
├── Sources/IDMCore/               Models & protocols, zero I/O, fully testable in isolation
│   ├── Models/                    DownloadTask, Chunk, DownloadState, DownloadError, ProgressUpdate
│   └── Protocols/                 DownloadEngineProtocol, ChunkWorkerProtocol, ResourceValidating, RetryPolicy
└── Sources/IDMEngine/              The actual concurrency + networking
    ├── DownloadEngine.swift        actor — owns tasks, plans chunks, drives workers, fans out progress
    ├── ChunkWorker.swift           actor — owns one byte-range: ranged GET, streamed disk write, retry
    ├── ResourceValidator.swift     HEAD request → size + range-support detection
    └── DefaultRetryPolicy.swift    exponential backoff
```

`IDM` (the app) depends on `IDMCore`/`IDMEngine` as a Swift Package. During active development it's referenced as a **local** package pointing at a sibling `../IDMCore` checkout, so the two can be iterated on together without round-tripping through GitHub; switch it back to the remote `XCRemoteSwiftPackageReference` (already configured, just needs the local one swapped back) once you're ready to depend on a pushed/tagged version.

```
                     ┌────────────────────────────────────────┐
                     │              SwiftUI (IDM)               │
                     │  ContentView → DownloadListStore         │
                     │       (⁠@Observable, MainActor)           │
                     └───────────────┬──────────────────────────┘
                                     │ start / pause / resume / cancel
                                     │ progressStream(for:) → AsyncStream
                     ┌───────────────▼──────────────────────────┐
                     │         DownloadEngine (actor)            │
                     │   owns every DownloadTask, plans chunks,   │
                     │   drives ChunkWorkers with bounded          │
                     │   concurrency, fans progress back out       │
                     └───────┬───────────────────┬────────────────┘
                             │                   │
                 ┌───────────▼──────┐   ┌────────▼─────────┐
                 │ ResourceValidator │   │  ChunkWorker × N   │
                 │      (actor)      │   │      (actor)        │
                 │  HEAD → size +    │   │  ranged GET, streams │
                 │  Accept-Ranges    │   │  to disk at the       │
                 └───────────────────┘   │  right offset, retries│
                                         └────────────────────────┘
```

Each `ChunkWorker` owns **its own independent file descriptor** into the destination file — a shared `FileHandle` across concurrently-seeking/writing workers would race and corrupt the output. Multiple file descriptors into the same file, each writing a disjoint byte range, is safe; that's the mechanism this relies on.

## Features

- Paste a URL, get a chunked, concurrent, resumable download
- Live progress: percentage, byte counts, and a smoothed transfer-speed estimate, pushed via `AsyncStream`
- Pause / resume / cancel / retry per download
- Falls back to a single whole-file download when a server doesn't support `Accept-Ranges` or doesn't report `Content-Length` — genuinely, not just in name (see [Corner cases found and fixed](#corner-cases-found-and-fixed))
- Survives app relaunch: the download list persists to disk, and a mid-flight download comes back paused with its exact per-chunk byte offsets intact, ready to resume rather than restart
- A short background grace period on backgrounding, used to pause cleanly and persist exact progress rather than let the process get suspended mid-write

## Requirements

- Xcode 26+ / Swift 5.9+
- iOS 16+ (package), 26.1 (this app target's current deployment target)
- A sibling checkout of [`IDMCore`](https://github.com/SWajahatAli/IDMCore) at `../IDMCore` relative to this repo (or point the package reference at the remote instead)

## Getting started

```bash
git clone https://github.com/SWajahatAli/IDMCore.git ../IDMCore   # sibling checkout
open IDM.xcodeproj
```

Build and run the `IDM` scheme on a simulator or device.

## Testing

Two independent test suites:

```bash
# Engine — models, protocols, actor orchestration (XCTest, mocked URLProtocol, no network)
cd ../IDMCore && swift test

# App layer — DownloadListStore, TaskStore (Swift Testing, mocked URLProtocol, no network)
# from Xcode: ⌘U on the IDM scheme, or:
xcodebuild -project IDM.xcodeproj -scheme IDM -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Both suites run entirely against a mocked `URLProtocol` — no real network access needed, and they're fast (well under a second for the engine's 25 tests). Real-network behavior is exercised separately via manual verification (see below), specifically because some real-world corner cases (see next section) only show up against an actual server, never a mock.

## Corner cases found and fixed

Three real bugs were found in this codebase while pressure-testing "does this actually work," each only surfacing once fully exercised — worth documenting because they're the kind of thing that's easy to miss and easy to reintroduce:

1. **Non-range-supporting servers always failed**, despite the engine explicitly falling back to a single whole-file chunk for them — `ChunkWorker` still unconditionally required a `206 Partial Content` response, which a non-range server correctly never sends (it sends `200`). Fixed by giving `ChunkWorker` an explicit whole-file mode that accepts `200` and treats the stream ending cleanly as completion, rather than checking against a byte count it can't actually predict.
2. **Downloads with no `Content-Length`** (e.g. chunked transfer encoding) **stopped after exactly one byte** — the chunk-planning fallback computed a `0...0` range when the total size was unknown. Fixed with a proper sentinel range plus the same whole-file completion signal as above.
3. **Range requests silently desynced against gzip-compressed responses.** Found by testing against a real CDN (GitHub's raw content, which gzips by default): `Content-Length` under compression describes the *compressed* size, but `Range` offsets only make sense against the *uncompressed* representation — two different coordinate systems. The engine would validate against one and request against the other, eventually failing once the byte accounting stopped adding up. This is a genuinely common real-world trap (most CDNs gzip by default) and never once showed up in a mocked test, since the mock never actually compresses anything. Fixed by sending `Accept-Encoding: identity` on every request the engine makes.

All three have regression tests. (3) was confirmed fixed by re-running against the real CDN: a 9,268-byte file split into 10 concurrent chunks reassembled byte-for-byte identical to a direct download.

## Known limitations

Documented deliberately, not hidden — these are the tradeoffs a careful reviewer would ask about first:

- **Not a true background `URLSession`.** iOS only grants indefinite background network access through delegate-based `URLSessionDownloadTask`, which is a fundamentally different, non-streaming API — incompatible with `ChunkWorker`'s `async/await` byte-range streaming. What's implemented instead is `beginBackgroundTask`: a short grace period (historically ~30s, not guaranteed) on backgrounding, used to pause cleanly and persist exact state. This means backgrounding via the **Home button** preserves your exact progress; **force-quitting** from the app switcher can kill the process before that code runs, and progress since the last state-change checkpoint may be lost. A real background-session implementation would mean rebuilding `ChunkWorker` around `URLSessionDownloadTask` + delegate + an `application(_:handleEventsForBackgroundURLSession:)` relaunch hook — a substantially different networking model, intentionally out of scope here.
- **`https://` only.** Plain `http://` URLs are rejected client-side rather than weakened via an app-wide `NSAllowsArbitraryLoads` ATS exception, which would trade away transport security for *every* request the app makes, not just user-supplied links. A per-domain ATS exception is the correct opt-in for a specific known `http` source; a generic downloader has no single domain to scope one to.
- **Retry re-enqueues, it doesn't resume.** A failed or cancelled task's partial file and chunk state are discarded, so "Retry" starts a fresh download rather than continuing the old one. Only a *paused* download resumes from its exact byte offset.
- **No download queue / concurrency cap across tasks.** Every added download starts immediately and runs independently; `maxConcurrentChunksPerTask` bounds chunks *within* one download, not the number of simultaneous downloads.
- **Byte-level streaming, not zero-copy.** `URLSession.AsyncBytes` only vends one `UInt8` at a time — there's no bulk-read entry point on the public API — so chunks are accumulated into a `[UInt8]` buffer and flushed to disk every 64 KB. Reasonably fast, not maximally so.

## Roadmap

- [x] Actor-based chunked download engine with pause/resume/cancel
- [x] Whole-file fallback for non-range/unknown-size servers
- [x] Live progress + transfer speed via `AsyncStream`
- [x] Persistence across relaunch
- [x] Real-network verification
- [ ] True background `URLSession` support (see Known Limitations)
- [ ] Share Extension — capture links from Safari instead of manual paste
- [ ] Download queueing with a configurable max concurrent *tasks*
- [ ] In-place retry (resume a failed task from its last good offset instead of restarting)

## License

Not yet chosen for this repo. `IDMCore` is MIT-licensed — see [its repository](https://github.com/SWajahatAli/IDMCore).
