import ReelCore
import SwiftUI

/// Browse the share's folders and pick one, for a library's location.
struct FolderPicker: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FolderList(path: "") { path in
                onPick(path)
                dismiss()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

private struct FolderList: View {
    let path: String
    let onPick: (String) -> Void

    @Environment(AppSettings.self) private var settings
    @State private var folders: [FileEntry]?
    @State private var videoCount = 0
    @State private var error: String?

    var body: some View {
        List {
            if !path.isEmpty {
                Section {
                    Button { onPick(path) } label: {
                        Label("Use This Folder", systemImage: "checkmark.circle.fill")
                    }
                } footer: {
                    if videoCount > 0 { Text("\(videoCount) video files directly in this folder.") }
                }
            }
            Section(path.isEmpty ? settings.shareConfig.displayName : "Folders") {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if let folders {
                    if folders.isEmpty { Text("No folders here.").foregroundStyle(.secondary) }
                    ForEach(folders, id: \.path) { folder in
                        NavigationLink(folder.name) { FolderList(path: folder.path, onPick: onPick) }
                    }
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle(path.isEmpty ? "Choose Folder" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let entries = try await ServerConnection.shared.source(for: settings.shareConfig).list(path)
                folders = entries.filter { $0.isDirectory && !$0.name.hasPrefix(".") }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                videoCount = entries.filter { !$0.isDirectory && MediaExtensions.video.contains(NameParser.fileExtension($0.name)) }.count
            } catch {
                self.error = LibrarySync.describe(error)
            }
        }
    }
}
