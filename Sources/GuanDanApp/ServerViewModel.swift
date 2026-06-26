import Foundation
import SwiftUI

/// ViewModel that manages the embedded game server and WebSocket bridge
@MainActor
final class ServerViewModel: ObservableObject {
    @Published var isServerRunning = false
    @Published var serverURL: String = ""
    @Published var port: UInt16 = 0

    private var server: GameHTTPServer?
    private var serverQueue = DispatchQueue(label: "game-server")

    /// Start the embedded game server
    func startServer() {
        guard !isServerRunning else { return }

        // Find the WebClient directory in the app bundle
        var webRoot: URL
        if let bundlePath = Bundle.main.resourcePath {
            webRoot = URL(fileURLWithPath: bundlePath).appendingPathComponent("WebClient")
        } else {
            // Fallback for development
            webRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/WebClient")
        }

        let srv = GameHTTPServer(webRoot: webRoot)
        do {
            try srv.start()
            self.server = srv
            // Wait for listener to be ready before showing URL
            srv.onReady = { [weak self] actualPort in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.port = actualPort
                    self.serverURL = "\(self.getLocalIPAddress()):\(actualPort)"
                    self.isServerRunning = true
                    print("[ServerViewModel] Server ready at \(self.serverURL)")
                }
            }

            // Wire up SSE broadcasts from RoomManager and MatchManager to the HTTP server
            setupBroadcastBridge(srv)

        } catch {
            print("[ServerViewModel] Failed to start server: \(error)")
        }
    }

    /// Stop the server
    func stopServer() {
        server?.stop()
        server = nil
        isServerRunning = false
        serverURL = ""
    }

    private func setupBroadcastBridge(_ srv: GameHTTPServer) {
        // RoomManager → SSE for room-level broadcasts
        RoomManager.shared.onBroadcast = { [weak srv] payload in
            let lines = payload.components(separatedBy: "\n")
            guard lines.count >= 1 else { return }
            let event = lines[0]
            let data = lines.count > 1 ? lines.dropFirst().joined(separator: "\n") : ""

            // Route gameState to specific player, broadcast everything else
            if event == "gameState",
               let jsonData = data.data(using: .utf8),
               let gs = try? JSONDecoder().decode(GameState.self, from: jsonData) {
                srv?.sendSSE(to: gs.playerId, event: event, data: data)
            } else {
                srv?.broadcastSSE(event: event, data: data)
            }
        }
        // Also forward Room's own broadcasts (set per-room below in startMatch)
    }

    /// Get the local Wi-Fi IP address for sharing with other players
    private func getLocalIPAddress() -> String {
        var address = "localhost"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return address }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let interface = ptr?.pointee else { continue }
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" { // Wi-Fi
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }
        return address
    }
}
