import Foundation


/// Manages a full match (series of games from 2 to A)
public final class MatchManager: @unchecked Sendable {
    public let room: Room
    public let players: [RoomPlayer]
    public let gameMode: GameMode
    public var onBroadcast: ((String, Data) -> Void)?

    public private(set) var teamLevels: [Int: Int] = [0: 2, 1: 2]
    public private(set) var activeTeam: Int = 0
    public private(set) var matchWinner: Int?
    public private(set) var consecutiveWins: [Int: Int] = [0: 0, 1: 0]
    public private(set) var currentGame: GameManager?
    private var lastWinners: [Int] = []

    public var isRunning: Bool { matchWinner == nil && currentGame != nil }

    public init(room: Room, players: [RoomPlayer], gameMode: GameMode) {
        self.room = room
        self.players = players
        self.gameMode = gameMode
    }

    public func startMatch() {
        teamLevels = [0: 2, 1: 2]
        activeTeam = 0
        consecutiveWins = [0: 0, 1: 0]
        matchWinner = nil
        lastWinners = []
        startNextGame()
    }

    public func startNextGame() {
        guard matchWinner == nil else { return }
        currentGame?.destroy()
        let game = GameManager(
            players: players,
            gameMode: gameMode,
            teamLevels: teamLevels,
            activeTeam: activeTeam,
            prevWinners: lastWinners
        )
        game.onBroadcast = { [weak self] event, data in
            self?.onBroadcast?(event, data)
            if event == "gameOver" {
                // Parse winners from data
                if let d = try? JSONDecoder().decode(GameOverData.self, from: data) {
                    self?.handleGameEnd(winners: d.winners)
                }
            }
        }
        currentGame = game
        // Forward GameManager broadcasts through MatchManager's callback chain
        game.onBroadcast = { [weak self] event, data in
            self?.onBroadcast?(event, data)
        }
        game.start()
    }

    private func handleGameEnd(winners: [Int]) {
        guard winners.count == 4 else { return }
        let (winningTeam, levelIncrease) = calculateLevelUp(winners)

        let oldLevel = teamLevels[winningTeam]!
        teamLevels[winningTeam] = min(oldLevel + levelIncrease, 14)
        let newLevel = teamLevels[winningTeam]!

        if winningTeam != activeTeam {
            activeTeam = winningTeam
        }

        if newLevel == 14 {
            consecutiveWins[winningTeam, default: 0] += 1
            consecutiveWins[1 - winningTeam] = 0

            if consecutiveWins[winningTeam]! >= 2 {
                matchWinner = winningTeam
                let winnerPlayers = players.filter { $0.seatIndex % 2 == winningTeam }
                let winnerNames = winnerPlayers.map { ["name": $0.name, "seatIndex": $0.seatIndex] }
                broadcast(event: "matchOver", data: [
                    "winningTeam": winningTeam,
                    "winners": winnerNames,
                    "finalLevels": teamLevels
                ] as [String: Any])
                return
            }
        } else {
            consecutiveWins = [0: 0, 1: 0]
        }

        lastWinners = winners
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.startNextGame()
        }
    }

    private func calculateLevelUp(_ winners: [Int]) -> (winningTeam: Int, levelIncrease: Int) {
        let p1 = winners[0], p2 = winners[1], p3 = winners[2]
        let sameTeam = { (a: Int, b: Int) in a % 2 == b % 2 }
        let winningTeam = p1 % 2
        let increase: Int
        if sameTeam(p1, p2) { increase = 3 }
        else if sameTeam(p1, p3) { increase = 2 }
        else { increase = 1 }
        return (winningTeam, increase)
    }

    public func forceEndMatch() {
        currentGame = nil
        matchWinner = nil
        consecutiveWins = [0: 0, 1: 0]
    }

    private func broadcast(event: String, data: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: data) else { return }
        onBroadcast?(event, json)
    }
}

struct GameOverData: Codable {
    let winners: [Int]
}
