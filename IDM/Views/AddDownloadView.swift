//
//  AddDownloadView.swift
//  IDM
//

import SwiftUI

struct AddDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    var store: DownloadListStore

    @State private var urlString: String = ""
    @State private var errorMessage: String?
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Download URL") {
                    TextField("https://example.com/file.zip", text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("New Download")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await addDownload() } }
                        .disabled(isAdding)
                }
            }
        }
    }

    private func addDownload() async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        // https only, deliberately: iOS blocks plain http:// via App Transport
        // Security by default, and the right fix for that is not weakening
        // ATS app-wide (NSAllowsArbitraryLoads) just to support it — that
        // trades away transport security for every request the app makes,
        // not just user-supplied download links. A per-domain ATS exception
        // is the correct opt-in for a specific known http source if one is
        // ever needed; a generic downloader has no single domain to scope it to.
        guard let url = URL(string: trimmed), url.scheme == "https" else {
            errorMessage = "Enter a valid https:// URL (plain http isn't supported — see ATS note in source)"
            return
        }

        isAdding = true
        await store.addDownload(url: url)
        isAdding = false
        dismiss()
    }
}

#Preview {
    AddDownloadView(store: DownloadListStore())
}
