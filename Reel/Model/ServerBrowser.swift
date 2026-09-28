import Foundation
import Network
import Observation

/// SMB servers advertising themselves over Bonjour: the same list the
/// Files app shows under Shared. Browsing is also what triggers iOS's Local
/// Network permission prompt.
@MainActor
@Observable
final class ServerBrowser {
    struct Server: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    private(set) var servers: [Server] = []
    /// The user said no to Local Network access. Nothing on the LAN is
    /// reachable until it's turned on in iOS Settings.
    private(set) var permissionDenied = false

    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Server? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return Server(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in
                self?.servers = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            // kDNSServiceErr_PolicyDenied
            if case .waiting(let error) = state, case .dns(let code) = error, code == -65570 {
                Task { @MainActor in self?.permissionDenied = true }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// The server's IPv4 address. An IP works for both the scanner and VLC,
    /// where a Bonjour name would need resolving twice.
    func address(of server: Server) async -> String? {
        await withCheckedContinuation { continuation in
            let parameters = NWParameters.tcp
            if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let connection = NWConnection(to: server.endpoint, using: parameters)
            var finished = false
            func finish(_ address: String?) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: address)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint {
                        var text = "\(host)"
                        if let scope = text.firstIndex(of: "%") { text = String(text[..<scope]) }
                        finish(text)
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish(nil) }
        }
    }
}
