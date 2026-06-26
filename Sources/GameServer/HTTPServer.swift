import Foundation
import Network


/// Lightweight HTTP + SSE server for the embedded game host
public final class GameHTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    public private(set) var port: UInt16 = 0
    public private(set) var isRunning = false

    private var sseClients: [String: SSEConnection] = [:]
    private let lock = NSLock()
    private var pendingBuffer: [ObjectIdentifier: Data] = [:]
    private let webRoot: URL
    public var onReady: ((UInt16) -> Void)?

    public typealias ActionHandler = (String, String, [String: Any]) -> Void

    public init(webRoot: URL) {
        self.webRoot = webRoot
    }

    // MARK: - Start/Stop

    public func start() throws {
        let fixedPort: UInt16 = 8080
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: fixedPort)!)
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let p = self.listener?.port?.rawValue {
                    self.port = p
                    self.onReady?(p)
                    print("[HTTPServer] Listening on port \(p)")
                }
                self.isRunning = true
            case .failed(let err):
                print("[HTTPServer] Failed: \(err)")
                self.isRunning = false
            default:
                break
            }
        }
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener?.start(queue: .main)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        sseClients.removeAll()
    }

    // MARK: - SSE broadcast

    public func broadcastSSE(event: String, data: String) {
        lock.lock()
        let clients = Array(sseClients.values)
        lock.unlock()
        for client in clients {
            client.send(event: event, data: data)
        }
    }

    /// Broadcast to a specific player's SSE connection
    public func sendSSE(to playerId: String, event: String, data: String) {
        lock.lock()
        let client = sseClients[playerId]
        lock.unlock()
        client?.send(event: event, data: data)
    }

    // MARK: - Connection handling

    private func handleConnection(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            if case .failed = state { conn.cancel() }
        }
        conn.start(queue: .main)
        receiveHTTP(conn)
    }

    private func receiveHTTP(_ conn: NWConnection) {
        let connId = ObjectIdentifier(conn)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { conn.cancel(); return }

            // Accumulate buffered data (TCP may split request across packets)
            var buffer = self.pendingBuffer[connId] ?? Data()
            buffer.append(data)
            self.pendingBuffer[connId] = buffer

            if let request = HTTPRequestParser.parse(buffer) {
                self.pendingBuffer.removeValue(forKey: connId)
                self.routeRequest(request, conn: conn)
            } else if buffer.count > 131072 {
                // Too large, give up
                self.pendingBuffer.removeValue(forKey: connId)
                self.sendResponse(conn, status: 400, body: "Bad Request")
        } else {
            // Need more data — schedule next receive AFTER callback returns
            DispatchQueue.main.async { [weak self] in
                self?.receiveHTTP(conn)
            }
        }
    }
    }

    // MARK: - Routing

    private func routeRequest(_ req: HTTPParsedRequest, conn: NWConnection) {
        let path = req.path

        // Health check
        if path == "/api/ping" {
            sendJSON(conn, dict: ["status": "ok", "time": Date().timeIntervalSince1970]); return
        }

        // SSE connections
        if path == "/api/events" {
            handleSSE(conn, req: req); return
        }

        // API endpoints
        if path == "/api/join", req.method == "POST" {
            handleJoin(conn, req: req); return
        }
        if path == "/api/action", req.method == "POST" {
            handleAction(conn, req: req); return
        }
        if path == "/api/room" {
            handleRoomInfo(conn); return
        }
        if path == "/api/room-list" {
            handleRoomList(conn); return
        }
        if path == "/api/start", req.method == "POST" {
            handleForceStart(conn, req: req); return
        }

        // Static files
        serveStatic(conn, path: path)
    }

    // MARK: - SSE

    private func handleSSE(_ conn: NWConnection, req: HTTPParsedRequest) {
        let playerId = req.queryParams["playerId"] ?? UUID().uuidString
        let client = SSEConnection(playerId: playerId, connection: conn)

        lock.lock()
        sseClients[playerId] = client
        lock.unlock()

        // Send SSE headers
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: text/event-stream\r\n"
        response += "Cache-Control: no-cache\r\n"
        response += "Connection: keep-alive\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "\r\n"
        conn.send(content: response.data(using: .utf8), completion: .idempotent)

        // Send current room state immediately (fixes race: join broadcasts before SSE is ready)
        if let room = RoomManager.shared.findPlayerRoom(playerId),
           let stateJson = try? JSONEncoder().encode(room.state),
           let stateStr = String(data: stateJson, encoding: .utf8) {
            client.send(event: "roomState", data: stateStr)
        }
    }

    // MARK: - API handlers

    private func handleJoin(_ conn: NWConnection, req: HTTPParsedRequest) {
        guard let body = req.jsonBody else { sendResponse(conn, status: 400, body: #"{"error":"invalid JSON"}"#); return }
        let name = body["playerName"] as? String ?? "Player"
        let roomId = body["roomId"] as? String ?? "default"

        let room = RoomManager.shared.getRoom(roomId)
        guard let player = room.addPlayer(id: req.queryParams["playerId"] ?? UUID().uuidString, name: name) else {
            let count = room.players.compactMap({$0}).count
            sendResponse(conn, status: 200, body: "{\"error\":\"Room full (\(count)/4 players)\",\"status\":\"full\"}")
            return
        }
        sendJSON(conn, dict: ["status": "ok", "playerId": player.id, "seatIndex": player.seatIndex])
    }

    private func handleAction(_ conn: NWConnection, req: HTTPParsedRequest) {
        guard let body = req.jsonBody else { sendResponse(conn, status: 400, body: #"{"error":"invalid JSON"}"#); return }
        let playerId = body["playerId"] as? String ?? ""
        let actionType = body["type"] as? String ?? ""
        let payload = body["payload"] as? [String: Any] ?? [:]

        guard let room = RoomManager.shared.findPlayerRoom(playerId) else {
            sendResponse(conn, status: 200, body: #"{"error":"player not found"}"#)
            return
        }
        handleGameAction(room: room, playerId: playerId, type: actionType, payload: payload)
        sendJSON(conn, dict: ["status": "ok"])
    }

    private func handleRoomInfo(_ conn: NWConnection) {
        let rooms = RoomManager.shared.roomList()
        guard let json = try? JSONEncoder().encode(rooms),
              let str = String(data: json, encoding: .utf8) else {
            sendResponse(conn, status: 500, body: "{}"); return
        }
        sendResponse(conn, status: 200, body: str, contentType: "application/json")
    }

    private func handleRoomList(_ conn: NWConnection) {
        handleRoomInfo(conn)
    }

    private func handleForceStart(_ conn: NWConnection, req: HTTPParsedRequest) {
        guard let body = req.jsonBody else { sendResponse(conn, status: 400, body: #"{"error":"invalid JSON"}"#); return }
        let playerId = body["playerId"] as? String ?? ""
        guard let room = RoomManager.shared.findPlayerRoom(playerId) else {
            sendResponse(conn, status: 200, body: #"{"error":"not in room"}"#); return
        }
        room.forceStart(playerId: playerId)
        sendJSON(conn, dict: ["status": "ok"])
    }

    private func handleGameAction(room: Room, playerId: String, type: String, payload: [String: Any]) {
        guard let game = room.matchManager?.currentGame else { return }
        guard let player = room.players.first(where: { $0?.id == playerId }), let seat = player?.seatIndex else { return }

        switch type {
        case "ready":
            room.setReady(playerId: playerId, ready: payload["ready"] as? Bool ?? true)
        case "playHand":
            guard let cardData = payload["cards"] as? [[String: Any]] else { return }
            let cards = cardData.compactMap { cardFromDict($0) }
            game.handlePlayHand(seatIndex: seat, cards: cards)
        case "pass":
            game.handlePass(seatIndex: seat)
        case "tribute":
            guard let cardData = payload["cards"] as? [[String: Any]], let c = cardFromDict(cardData.first ?? [:]) else { return }
            game.handleTribute(seatIndex: seat, cards: [c])
        case "returnTribute":
            guard let cardData = payload["cards"] as? [[String: Any]], let c = cardFromDict(cardData.first ?? [:]) else { return }
            game.handleReturnTribute(seatIndex: seat, cards: [c])
        case "useSkill":
            game.handleUseSkill(seatIndex: seat, skillId: payload["skillId"] as? String ?? "", targetSeat: payload["targetSeat"] as? Int)
        case "switchSeat":
            room.switchSeat(playerId: playerId, targetSeat: payload["targetSeat"] as? Int ?? 0)
        case "chatMessage":
            room.chatMessage(playerId: playerId, text: payload["text"] as? String ?? "")
        case "setGameMode":
            // Host only
            let modeStr = payload["mode"] as? String ?? "Normal"
            room.gameMode = GameMode(rawValue: modeStr) ?? .normal
            room.broadcastState()
        case "forceEndGame":
            room.matchManager?.forceEndMatch()
            room.matchManager = nil
            for i in 0..<4 { if var p = room.players[i] { p.isReady = false; room.players[i] = p } }
            room.broadcastState()
        default:
            break
        }
    }

    // MARK: - Static file serving

    private func serveStatic(_ conn: NWConnection, path: String) {
        let route = path == "/" ? "/index.html" : path
        guard let asset = WebAssets.content[route] else {
            sendResponse(conn, status: 404, body: "Not Found"); return
        }
        sendResponseData(conn, status: 200, data: asset.data, contentType: asset.mime)
    }

    // MARK: - Response helpers

    private func sendResponse(_ conn: NWConnection, status: Int, body: String, contentType: String = "application/json") {
        guard let data = body.data(using: .utf8) else { return }
        sendResponseData(conn, status: status, data: data, contentType: contentType)
    }

    private func sendResponseData(_ conn: NWConnection, status: Int, data: Data, contentType: String) {
        let statusText = HTTPStatus.text(status)
        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(data.count)\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        var out = response.data(using: .utf8) ?? Data()
        out.append(data)
        conn.send(content: out, completion: .contentProcessed({ _ in conn.cancel() }))
    }

    private func sendJSON(_ conn: NWConnection, dict: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: json, encoding: .utf8) else { return }
        sendResponse(conn, status: 200, body: str)
    }

    // MARK: - Helpers

    private func cardFromDict(_ dict: [String: Any]) -> Card? {
        guard let suitRaw = dict["suit"] as? Int,
              let rankRaw = dict["rank"] as? Int,
              let id = dict["id"] as? String,
              let suit = Suit(rawValue: suitRaw),
              let rank = Rank(rawValue: rankRaw) else { return nil }
        var card = Card(suit: suit, rank: rank, id: id)
        card.isLevelCard = dict["isLevelCard"] as? Bool ?? false
        card.isWild = dict["isWild"] as? Bool ?? false
        return card
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": "text/html"
        case "css": "text/css"
        case "js": "application/javascript"
        case "json": "application/json"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "svg": "image/svg+xml"
        case "ico": "image/x-icon"
        default: "application/octet-stream"
        }
    }
}

// MARK: - SSE Connection

final class SSEConnection {
    let playerId: String
    let connection: NWConnection
    private let queue = DispatchQueue(label: "sse.\(UUID().uuidString)")

    init(playerId: String, connection: NWConnection) {
        self.playerId = playerId
        self.connection = connection
    }

    func send(event: String, data: String) {
        let lines = data.components(separatedBy: "\n").map { "data: \($0)" }.joined(separator: "\n")
        let msg = "event: \(event)\n\(lines)\n\n"
        guard let payload = msg.data(using: .utf8) else { return }
        connection.send(content: payload, completion: .idempotent)
    }
}

// MARK: - HTTP Parsing

struct HTTPParsedRequest {
    let method: String
    let path: String
    let queryParams: [String: String]
    let headers: [String: String]
    let body: Data?

    var jsonBody: [String: Any]? {
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

enum HTTPRequestParser {
    static func parse(_ data: Data) -> HTTPParsedRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Find the FIRST \r\n\r\n boundary — components() would split all occurrences
        guard let headerEnd = text.range(of: "\r\n\r\n") else { return nil }
        let headerSection = String(text[..<headerEnd.lowerBound])
        let bodyData = text[headerEnd.upperBound...].data(using: .utf8)

        var lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let reqParts = requestLine.components(separatedBy: " ")
        guard reqParts.count >= 2 else { return nil }
        let method = reqParts[0]
        let fullPath = reqParts[1]

        // Parse query params
        let pathComponents = fullPath.components(separatedBy: "?")
        let path = pathComponents[0]
        var queryParams: [String: String] = [:]
        if pathComponents.count > 1 {
            for pair in pathComponents[1].components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 {
                    queryParams[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                }
            }
        }

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines where line.contains(":") {
            let kv = line.components(separatedBy: ": ")
            if kv.count >= 2 {
                headers[kv[0].lowercased()] = kv.dropFirst().joined(separator: ": ")
            }
        }

        return HTTPParsedRequest(method: method, path: path, queryParams: queryParams, headers: headers, body: bodyData)
    }
}

// MARK: - HTTP Status

enum HTTPStatus {
    static func text(_ code: Int) -> String {
        switch code {
        case 200: "OK"; case 400: "Bad Request"
        case 404: "Not Found"; case 500: "Internal Server Error"
        default: "Unknown"
        }
    }
}
