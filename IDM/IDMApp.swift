//
//  IDMApp.swift
//  IDM
//
//  Created by Wajahat Ali on 14/08/2026.
//

import SwiftUI

@main
struct IDMApp: App {
    @State private var store = DownloadListStore()
    @State private var backgroundTaskCoordinator = BackgroundTaskCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                backgroundTaskCoordinator.run {
                    await store.pauseAllActiveDownloads()
                    await store.persistNow()
                }
            case .active:
                backgroundTaskCoordinator.end()
            default:
                break
            }
        }
    }
}
