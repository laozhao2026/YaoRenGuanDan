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
        game.onBroadcast = { [weak self] (event: String, data: Data) in
            self?.onBroadcast?(event, data)
            if event == "gameOver" {
                // Parse winners from data
                if let d = try? JSONDecoder().decode(GameOverData.self, from: data) {
                    self?.handleGameEnd(winners: d.winners)
                }
            }
        }
        currentGame = game
        game.start()
    }

    private func handleGameEnd(winners: [Int]) {
        var allWinners = winners
        // Fill 4th place if only 3 winners (game can end when 3 finish)
        if winners.count == 3 {
            if let last = [0,1,2,3].first(where: { !winners.contains($0) }) {
                allWinners.append(last)
            }
        }
        guard allWinners.count == 4 else { return }
        let (winningTeam, levelIncrease) = calculateLevelUp(allWinners)

        let oldLevel = teamLevels[winningTeam]!
        teamLevels[winningTeam] = min(oldLevel + levelIncrease, 14)
        let newLevel = teamLevels[winningTeam]!

        if winningTeam != activeTeam {
            activeTeam = winningTeam
        }

        // Broadcast game result (convert Int keys to String for JSONSerialization)
        let strLevels: [String: Int] = [
            "0": teamLevels[0]!,
            "1": teamLevels[1]!
        ]
        let winnerNames = winners.map { idx -> String in
            let p = players.first(where: { $0.seatIndex == idx })
            return p?.name ?? "Bot \(idx)"
        }
        broadcast(event: "gameResult", data: [
            "winners": allWinners,
            "winnerNames": winnerNames,
            "winningTeam": winningTeam,
            "levelFrom": oldLevel,
            "levelTo": newLevel,
            "levelIncrease": levelIncrease,
            "oldLevels": strLevels,
            "activeTeam": activeTeam,
            "hasTribute": lastWinners.count == 4
        ] as [String : Any])

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
                    "finalLevels": strLevels
                ] as [String: Any])
                return
            }
        } else {
            consecutiveWins = [0: 0, 1: 0]
        }

        lastWinners = allWinners
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
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
