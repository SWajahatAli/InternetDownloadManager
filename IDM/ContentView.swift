//
//  ContentView.swift
//  IDM
//
//  Created by Wajahat Ali on 14/08/2026.
//

import SwiftUI

struct ContentView: View {
    var store: DownloadListStore
    @State private var isShowingAddSheet = false

    var body: some View {
        NavigationStack {
            Group {
                if store.tasks.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Tap + to add a download")
                    )
                } else {
                    List {
                        ForEach(store.tasks) { task in
                            DownloadRowView(task: task, store: store)
                        }
                    }
                }
            }
            .navigationTitle("IDM")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $isShowingAddSheet) {
                AddDownloadView(store: store)
            }
            .task {
                await store.restorePersistedTasks()
            }
        }
    }
}

#Preview {
    ContentView(store: DownloadListStore())
}
