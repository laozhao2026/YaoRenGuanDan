import Foundation


/// Represents a player in a room
public struct RoomPlayer: Identifiable {
    public var id: String
    public var name: String
    public var seatIndex: Int
    public var isReady: Bool = false
    public var isBot: Bool = false
    public var isDisconnected: Bool = false

    public init(id: String, name: String, seatIndex: Int, isReady: Bool = false, isBot: Bool = false) {
        self.id = id
        self.name = name
        self.seatIndex = seatIndex
        self.isReady = isReady
        self.isBot = isBot
    }
}

/// Room state serialized for clients
public struct RoomState: Codable {
    public let roomId: String
    public let players: [PlayerInfo?]
    public let gameMode: String

    public struct PlayerInfo: Codable {
        public var id: String
        public let name: String
        public let seatIndex: Int
        public let isReady: Bool
        public let isBot: Bool
    }
}

/// Manages rooms — singleton that owns all rooms
public final class RoomManager {
    nonisolated(unsafe) public static let shared = RoomManager()

    private var rooms: [String: Room] = [:]
    private let queue = DispatchQueue(label: "com.guandan.roommanager")
    public var onBroadcast: ((String) -> Void)?

    /// Get or create a room
    public func getRoom(_ roomId: String) -> Room {
        queue.sync {
        if let room = rooms[roomId] { return room }
        let room = Room(id: roomId)
        rooms[roomId] = room
        return room
        }
    }

    /// Remove a room
    public func removeRoom(_ roomId: String) {
        queue.sync {
        rooms.removeValue(forKey: roomId)
        }
    }

    /// List all rooms
    public func roomList() -> [RoomState] {
        queue.sync {
        return rooms.values.map { $0.state }
        }
    }

    /// Find which room a player is in
    public func findPlayerRoom(_ playerId: String) -> Room? {
        queue.sync {
        return rooms.values.first { $0.hasPlayer(playerId) }
    }
    }
}

/// A single room holding players, match, and game state
public final class Room {
    public var id: String
    public var players: [RoomPlayer?] = [nil, nil, nil, nil]
    public var matchManager: MatchManager?
    public var gameMode: GameMode = .normal
    public var onBroadcast: ((String) -> Void)?

    public init(id: String) {
        self.id = id
    }

    public var state: RoomState {
        let infos: [RoomState.PlayerInfo?] = players.map { p in
            guard let p else { return nil }
            return RoomState.PlayerInfo(id: p.id, name: p.name, seatIndex: p.seatIndex, isReady: p.isReady, isBot: p.isBot)
        }
        return RoomState(roomId: id, players: infos, gameMode: gameMode.rawValue)
    }

    public func hasPlayer(_ playerId: String) -> Bool {
        players.contains { $0?.id == playerId }
    }

    /// Add or reconnect a player
    @discardableResult
    public func addPlayer(id: String, name: String) -> RoomPlayer? {
        // Check reconnection
        if let idx = players.firstIndex(where: { $0?.name == name && $0?.isDisconnected == true }) {
            var p = players[idx]!
            p.isDisconnected = false
            p.id = id
            players[idx] = p
            broadcastState()
            return p
        }

        // Find empty seat
        guard let seatIdx = players.firstIndex(where: { $0 == nil }) else { return nil }
        let player = RoomPlayer(id: id, name: name, seatIndex: seatIdx)
        players[seatIdx] = player
        broadcastState()
        return player
    }

    /// Disconnect a player
    public func disconnectPlayer(id: String) {
        guard let idx = players.firstIndex(where: { $0?.id == id }) else { return }
        var p = players[idx]!

        if matchManager?.isRunning == true {
            p.isDisconnected = true
            players[idx] = p
        } else {
            players[idx] = nil
        }
        broadcastState()
    }

    /// Set player ready
    public func setReady(playerId: String, ready: Bool) {
        guard let idx = players.firstIndex(where: { $0?.id == playerId }) else { return }
        players[idx]?.isReady = ready
        broadcastState()
        tryAutoStart()
    }

    /// Switch seat
    public func switchSeat(playerId: String, targetSeat: Int) {
        guard matchManager?.isRunning != true else { return }
        guard let currentIdx = players.firstIndex(where: { $0?.id == playerId }),
              players[targetSeat] == nil else { return }
        var p = players[currentIdx]!
        p.seatIndex = targetSeat
        players[targetSeat] = p
        players[currentIdx] = nil
        broadcastState()
    }

    /// Force start (host only)
    public func forceStart(playerId: String) {
        guard let idx = players.firstIndex(where: { $0?.id == playerId }),
              idx == 0 else { return }
        guard matchManager?.isRunning != true else { return }
        startMatch()
    }

    /// Handle chat message
    public func chatMessage(playerId: String, text: String) {
        guard let p = players.compactMap({ $0 }).first(where: { $0.id == playerId }) else { return }
        let msg = ChatMessage(sender: p.name, text: text, seatIndex: p.seatIndex)
        broadcast(event: "chatMessage", data: msg)
    }

    // MARK: - Internal

    private func tryAutoStart() {
        let readyCount = players.compactMap { $0 }.filter(\.isReady).count
        if readyCount == 4 { startMatch() }
    }

    private func startMatch() {
        // Fill empty seats with bots
        let gamePlayers: [RoomPlayer] = (0..<4).map { i in
            if let p = players[i] { return p }
            return RoomPlayer(id: "bot-\(i)", name: "Bot \(i)", seatIndex: i, isReady: true, isBot: true)
        }
        players = gamePlayers
        broadcastState()

        // Create and start match
        matchManager = MatchManager(room: self, players: gamePlayers, gameMode: gameMode)
        // Wire match/game broadcasts to SSE via RoomManager
        matchManager?.onBroadcast = { [weak self] event, data in
            guard let jsonStr = String(data: data, encoding: .utf8) else { return }
            let payload = "\(event)\n\(jsonStr)\n"
            RoomManager.shared.onBroadcast?(payload)
        }
        matchManager?.startMatch()
        broadcast(event: "matchStarted", data: JSONBox(["started": .bool(true)]))
    }

    public func broadcastState() {
        broadcast(event: "roomState", data: state)
    }

    public func broadcast<T: Encodable>(event: String, data: T) {
        guard let json = try? JSONEncoder().encode(data) else { return }
        let payload = "\(event)\n\(String(data: json, encoding: .utf8)!)\n"
        if let cb = onBroadcast {
            cb(payload)
        } else {
            RoomManager.shared.onBroadcast?(payload)
        }
    }
}

/// Simple JSON wrapper
public struct JSONBox: Encodable {
    public let dict: [String: JSONValue]
    public init(_ dict: [String: JSONValue]) { self.dict = dict }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        for (k, v) in dict {
            try c.encode(v, forKey: DynamicKey(stringValue: k)!)
        }
    }
}

public enum JSONValue: Encodable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
}

public struct DynamicKey: CodingKey {
    public var stringValue: String
    public var intValue: Int?
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { nil }
}

public struct ChatMessage: Codable {
    public let sender: String
    public let text: String
    public let seatIndex: Int
}
