import ReelCore
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibrarySync.self) private var sync
    @Environment(\.modelContext) private var context

    @State private var testResult: TestResult?
    @State private var testing = false
    @State private var shareFolders: [String] = []
    @State private var editing: LibraryConfig?

    enum TestResult {
        case ok(String)
        case failed(String)
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                TextField("Address", text: $settings.host, prompt: Text("192.168.8.1"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Share", text: $settings.share, prompt: Text("media"))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Username", text: $settings.username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $settings.password)
                    .textContentType(.password)
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing || settings.host.isEmpty)
                if let testResult {
                    switch testResult {
                    case .ok(let message): Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let message): Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            } header: {
                Text("SMB Server")
            } footer: {
                Text("The router's IP address or hostname. Leave the share empty and tap Test Connection to list the shares it offers.")
            }

            Section {
                ForEach(settings.libraries) { library in
                    Button { editing = library } label: {
                        HStack {
                            Label(library.name, systemImage: library.systemImage)
                            Spacer()
                            Text(library.path).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { settings.libraries.remove(atOffsets: $0) }
                Button {
                    editing = LibraryConfig(name: "", path: "", kind: .movies, useTMDB: true)
                } label: {
                    Label("Add Library", systemImage: "plus")
                }
            } header: {
                Text("Libraries")
            } footer: {
                Text("Each library is a folder in the share. Movies expects one folder per movie; TV expects one folder per show.")
            }

            Section {
                SecureField("API key or read access token", text: $settings.tmdbKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Link("Get a free key at themoviedb.org", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
            } header: {
                Text("Posters & Descriptions (TMDB)")
            } footer: {
                Text("Optional. Without a key, titles come from the file names and there's no artwork.")
            }

            Section {
                Button {
                    Task { await sync.run(settings: settings, context: context) }
                } label: {
                    HStack {
                        Text("Scan Now")
                        Spacer()
                        if sync.isRunning { ProgressView() }
                    }
                }
                .disabled(!settings.isConfigured || sync.isRunning)

                Button("Re-fetch All Metadata") {
                    sync.resetMetadata(context: context)
                    Task { await sync.run(settings: settings, context: context) }
                }
                .disabled(!settings.isConfigured || sync.isRunning || settings.tmdbKey.isEmpty)

                Button("Clear Artwork Cache") {
                    Task { await ArtworkStore.shared.clear() }
                }
            } footer: {
                syncFooter
            }
        }
        .navigationTitle("Settings")
        .sheet(item: $editing) { library in
            LibraryEditor(library: library, folders: shareFolders) { saved in
                if let i = settings.libraries.firstIndex(where: { $0.id == saved.id }) {
                    settings.libraries[i] = saved
                } else {
                    settings.libraries.append(saved)
                }
            }
        }
    }

    @ViewBuilder
    private var syncFooter: some View {
        switch sync.state {
        case .scanning(let message): Text(message)
        case .failed(let message): Text(message).foregroundStyle(.red)
        case .idle:
            if let last = sync.lastSync {
                Text("Last scanned \(last.formatted(.relative(presentation: .named))).")
            }
        }
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        let config = settings.smbConfig
        do {
            if config.share.isEmpty {
                let shares = try await SMBFileSource.listShares(config: config)
                testResult = .ok(shares.isEmpty ? "Connected, but no shares are visible." : "Shares: " + shares.joined(separator: ", "))
            } else {
                let entries = try await ServerConnection.shared.source(for: config).list("")
                shareFolders = entries.filter(\.isDirectory).map(\.name).filter { !$0.hasPrefix(".") }.sorted()
                testResult = .ok("Connected. Folders: " + shareFolders.prefix(8).joined(separator: ", ")
                                 + (shareFolders.count > 8 ? "…" : ""))
            }
        } catch {
            testResult = .failed(LibrarySync.describe(error))
        }
    }
}

struct LibraryEditor: View {
    @State var library: LibraryConfig
    let folders: [String]
    let onSave: (LibraryConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $library.name, prompt: Text("Movies"))
                HStack {
                    TextField("Folder", text: $library.path, prompt: Text("movies"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !folders.isEmpty {
                        Menu {
                            ForEach(folders, id: \.self) { folder in
                                Button(folder) { library.path = folder }
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                    }
                }
                Picker("Contains", selection: $library.kind) {
                    Text("Movies").tag(LibraryKind.movies)
                    Text("TV Shows").tag(LibraryKind.shows)
                }
                Toggle("Look up on TMDB", isOn: $library.useTMDB)
            }
            .navigationTitle(library.name.isEmpty ? "New Library" : library.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(library)
                        dismiss()
                    }
                    .disabled(library.name.isEmpty || library.path.isEmpty)
                }
            }
        }
    }
}
