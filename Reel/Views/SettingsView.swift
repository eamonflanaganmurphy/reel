import ReelCore
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibrarySync.self) private var sync
    @Environment(ProgressSync.self) private var progress
    @Environment(\.modelContext) private var context

    @State private var testResult: TestResult?
    @State private var testing = false
    @State private var shares: [String] = []
    @State private var editing: LibraryConfig?
    @State private var browser = ServerBrowser()
    @State private var resolving: String?
    /// Library folders found somewhere else in the share, offered as a fix.
    @State private var foundPaths: [UUID: String] = [:]

    enum TestResult {
        case ok(String)
        case failed(String)
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            if !browser.servers.isEmpty || browser.permissionDenied {
                Section {
                    if browser.permissionDenied {
                        Label("Reel isn't allowed on the local network. Turn on Settings → Reel → Local Network.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    ForEach(browser.servers) { server in
                        Button {
                            Task { await choose(server) }
                        } label: {
                            HStack {
                                Label(server.name, systemImage: "externaldrive.connected.to.line.below")
                                Spacer()
                                if resolving == server.name { ProgressView() }
                            }
                        }
                    }
                } header: {
                    Text("Nearby Servers")
                }
            }

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
                ForEach(shares, id: \.self) { name in
                    Button {
                        settings.share = name
                        shares = []
                        Task { await testConnection() }
                    } label: {
                        Label(name, systemImage: "folder")
                    }
                }
            } header: {
                Text("SMB Server")
            } footer: {
                Text("Pick the router under Nearby Servers, or type its IP address. Leave Share empty and tap Test Connection to list its shares. Leave Username and Password empty for guest access.")
            }

            if !foundPaths.isEmpty {
                Section {
                    ForEach(settings.libraries.filter { foundPaths[$0.id] != nil }) { library in
                        LabeledContent(library.name, value: foundPaths[library.id] ?? "")
                    }
                    Button("Use These Folders") {
                        for i in settings.libraries.indices {
                            if let path = foundPaths[settings.libraries[i].id] { settings.libraries[i].path = path }
                        }
                        foundPaths = [:]
                        Task { await sync.run(settings: settings, context: context) }
                    }
                } header: {
                    Text("Library Folders Found")
                } footer: {
                    Text("These libraries' folders aren't where Reel expected, but folders with the same names are in the share.")
                }
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
                switch progress.status {
                case .idle:
                    Label("Not synced yet", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                case .synced(let date):
                    Label("Synced \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Watch Progress")
            } footer: {
                Text("Where you got to in each video is saved in a hidden .reel folder on the share, so every phone running Reel picks up in the same place. The login needs permission to write to the share.")
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

                Button("Clear Saved Artwork") {
                    Task { await ArtworkStore.shared.clear() }
                }
            } footer: {
                syncFooter
            }
        }
        .navigationTitle("Settings")
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        .sheet(item: $editing) { library in
            LibraryEditor(library: library) { saved in
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

    private func choose(_ server: ServerBrowser.Server) async {
        resolving = server.name
        defer { resolving = nil }
        if let address = await browser.address(of: server) {
            settings.host = address
        } else {
            settings.host = server.name.replacingOccurrences(of: " ", with: "-") + ".local"
        }
        await testConnection()
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        shares = []
        foundPaths = [:]
        let note = await settings.tidyAddress()
        let config = settings.smbConfig
        do {
            if config.share.isEmpty {
                let names = try await SMBFileSource.listShares(config: config)
                shares = names
                testResult = .ok(names.isEmpty
                    ? "Connected, but the server lists no shares. Type the share name in Share."
                    : "Connected. Pick a share:")
                return
            }
            let source = try ServerConnection.shared.source(for: config)
            let top = try await source.list("")
            var message = "Connected to “\(config.share)”."
            if let note { message += " " + note }

            // Check each library's folder, and look for any that are missing.
            var missing: [LibraryConfig] = []
            for library in settings.libraries {
                let exists = (try? await source.list(library.path)) != nil
                if !exists { missing.append(library) }
            }
            if !missing.isEmpty {
                let names = missing.map { ($0.path as NSString).lastPathComponent }
                let found = try await LibraryLocator(source: source).find(names)
                for library in missing {
                    if let path = found[(library.path as NSString).lastPathComponent] { foundPaths[library.id] = path }
                }
                let stillMissing = missing.filter { foundPaths[$0.id] == nil }.map(\.name)
                if !stillMissing.isEmpty {
                    message += " Couldn't find the folder for " + stillMissing.joined(separator: ", ")
                        + ". Set it under Libraries. Top-level folders: "
                        + top.filter(\.isDirectory).map(\.name).filter { !$0.hasPrefix(".") }.prefix(8).joined(separator: ", ")
                }
            }
            testResult = .ok(message)
        } catch {
            testResult = .failed(LibrarySync.describe(error))
        }
    }
}

struct LibraryEditor: View {
    @State var library: LibraryConfig
    let onSave: (LibraryConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $library.name, prompt: Text("Movies"))
                HStack {
                    TextField("Folder", text: $library.path, prompt: Text("movies"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button { picking = true } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless)
                }
                Picker("Contains", selection: $library.kind) {
                    Text("Movies").tag(LibraryKind.movies)
                    Text("TV Shows").tag(LibraryKind.shows)
                }
                Toggle("Look up on TMDB", isOn: $library.useTMDB)
            }
            .sheet(isPresented: $picking) {
                FolderPicker { library.path = $0 }
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
