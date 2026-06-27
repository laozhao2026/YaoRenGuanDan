import Foundation


/// Manages a single game (one round of play)
public final class GameManager {
    public let players: [RoomPlayer]
    public let gameMode: GameMode
    public let level: Int
    public let activeTeam: Int
    public var teamLevels: [Int: Int]
    public var onBroadcast: ((String, Data) -> Void)?

    public private(set) var phase = GamePhase.waiting
    public private(set) var hands: [[Card]] = [[], [], [], []]
    public private(set) var currentTurn: Int = 0
    public private(set) var lastHand: (playerIndex: Int, hand: Hand)?
    public private(set) var passCount: Int = 0
    public private(set) var winners: [Int] = []
    public private(set) var roundActions: [Int: RoundAction] = [:]
    public private(set) var tributeState = TributeState()
    public private(set) var skillCards: [[SkillCard]] = [[], [], [], []]
    public private(set) var skipNextTurn: [Bool] = [false, false, false, false]
    public private(set) var history: [HistoryEntry] = []
    public private(set) var currentRound: Int = 1

    private var isActive = true
    private var pendingTimers: [DispatchWorkItem] = []
    private var prevWinners: [Int]
    private var historyIdCounter = 0
    private var newCardIds: [Int: [String]] = [:]
    public let logger = GameLogger()

    // MARK: - Init

    public init(players: [RoomPlayer], gameMode: GameMode, teamLevels: [Int: Int], activeTeam: Int, prevWinners: [Int]) {
        self.players = players
        self.gameMode = gameMode
        self.teamLevels = teamLevels
        self.activeTeam = activeTeam
        self.level = teamLevels[activeTeam] ?? 2
        self.prevWinners = prevWinners
    }

    // MARK: - Start

    public func start() {
        isActive = true
        phase = .dealing
        history = []
        historyIdCounter = 0
        winners = []

        let deck = shuffleDeck(createDeck())
        hands = [[], [], [], []]
        for i in 0..<108 { hands[i % 4].append(deck[i]) }
        hands = hands.map { updateCardProperties($0, level: level) }
        hands = hands.map { sortCards($0, level: level) }

        skipNextTurn = [false, false, false, false]
        newCardIds = [:]

        if gameMode == .skill { dealSkillCards() }

        if !prevWinners.isEmpty {
            initTributePhase()
        } else {
            currentTurn = 0
            phase = .playing
            passCount = 0
            lastHand = nil
        }
        broadcastGameState()
    }

    // MARK: - Player actions

    public func handlePlayHand(seatIndex: Int, cards: [Card]) {
        guard phase == .playing, currentTurn == seatIndex else {
            logger.logTurn("play_rejected", seatIndex: seatIndex, detail: "phase=\(phase.rawValue) currentTurn=\(currentTurn) expected=\(seatIndex)")
            return
        }
        guard let hand = getHandType(cards, level: level) else {
            logger.logTurn("play_invalid_hand", seatIndex: seatIndex, detail: "cards=\(cards.map(\.id).joined(separator: ","))")
            emitError(seatIndex, "Invalid hand"); return
        }

        if let last = lastHand, last.playerIndex != seatIndex {
            // Must beat or pass
            if compareHands(hand, last.hand) <= 0 {
                logger.logTurn("play_not_larger", seatIndex: seatIndex, detail: "hand=\(hand.type.rawValue) lastHand=\(last.hand.type.rawValue)")
                emitError(seatIndex, "Must play a larger hand or pass"); return
            }
        }

        // Validate cards in hand
        let handIds = Set(hands[seatIndex].map(\.id))
        for c in cards {
            guard handIds.contains(c.id) else {
                logger.logTurn("play_card_not_found", seatIndex: seatIndex, detail: "cardId=\(c.id)")
                emitError(seatIndex, "Card not in hand"); return
            }
        }

        // Remove played cards
        let playedIds = Set(cards.map(\.id))
        hands[seatIndex].removeAll { playedIds.contains($0.id) }

        lastHand = (seatIndex, hand)
        passCount = 0
        roundActions[seatIndex] = RoundAction(type: "play", cards: cards, hand: hand)

        let playerName = players[seatIndex].name
        let isBot = players[seatIndex].isBot
        addHistory(.play, "\(playerName) played \(handDescription(hand))", seatIndex)
        logger.logTurn("play", seatIndex: seatIndex, detail: "\(isBot ? "[BOT]" : "") type=\(hand.type.rawValue) cards=\(cards.map { cardDesc($0) }.joined(separator: " ")) remaining=\(hands[seatIndex].count)")

        // Check win
        if hands[seatIndex].isEmpty {
            winners.append(seatIndex)
            logger.logTurn("player_finish", seatIndex: seatIndex, detail: "rank=\(winners.count) winners=[\(winners.map(String.init).joined(separator: ","))]")
            // Double win: 1st and 2nd same team → auto end
            if winners.count == 2 {
                if winners[0] % 2 == winners[1] % 2 {
                    logger.log("double_win", detail: "team=\(winners[0]%2) auto_end")
                    let losers = [0,1,2,3].filter { !winners.contains($0) }
                    winners.append(contentsOf: losers)
                    endGame(); return
                }
            }
            addHistory(.playerFinish, "\(playerName) finished #\(winners.count)", seatIndex)
            if winners.count >= 3 {
                let last = [0,1,2,3].first(where: { !winners.contains($0) })!
                winners.append(last)
                endGame(); return
            }
        }

        logger.log("advance_turn", detail: "from seat=\(seatIndex) winners=[\(winners.map(String.init).joined(separator: ","))]")
        advanceTurn()
        broadcastGameState()
    }

    public func handlePass(seatIndex: Int) {
        guard phase == .playing, currentTurn == seatIndex else {
            logger.logTurn("pass_rejected", seatIndex: seatIndex, detail: "phase=\(phase.rawValue) currentTurn=\(currentTurn)")
            return
        }
        guard lastHand != nil, lastHand?.playerIndex != seatIndex else {
            logger.logTurn("pass_free_turn_rejected", seatIndex: seatIndex)
            emitError(seatIndex, "Cannot pass on free turn"); return
        }

        passCount += 1
        roundActions[seatIndex] = RoundAction(type: "pass")
        addHistory(.pass, "\(players[seatIndex].name) passed", seatIndex)
        logger.logTurn("pass", seatIndex: seatIndex, detail: "passCount=\(passCount)/3 lastPlayer=\(lastHand?.playerIndex ?? -1)")

        // Reset round if 3 consecutive passes
        if passCount >= 3 {
            let lastPlayer = lastHand?.playerIndex
            passCount = 0
            lastHand = nil
            roundActions = [:]
            // 接风：round winner leads (or partner if winner finished)
            if let lp = lastPlayer {
                currentTurn = winners.contains(lp) ? (lp + 2) % 4 : lp
            }
            logger.log("round_reset", detail: "newTurn=\(currentTurn) winners=[\(winners.map(String.init).joined(separator: ","))]")
        } else {
            advanceTurn()
        }

        broadcastGameState()
    }

    public func handleTribute(seatIndex: Int, cards: [Card]) {
        guard phase == .tribute, let idx = tributeState.pendingTributes.firstIndex(where: { $0.from == seatIndex && $0.card == nil }) else { return }
        guard cards.count == 1 else { return }

        let hand = hands[seatIndex]
        let largest = getLargestCard(hand, level: level)
        let valPlay = getLogicValue(rank: cards[0].rank, level: level)
        let valMax = getLogicValue(rank: largest.rank, level: level)
        guard valPlay >= valMax else { emitError(seatIndex, "Must pay the largest card"); return }

        tributeState.pendingTributes[idx].card = cards[0]
        hands[seatIndex].removeAll { $0.id == cards[0].id }
        let to = tributeState.pendingTributes[idx].to
        hands[to].append(cards[0])
        hands[to] = sortCards(hands[to], level: level)

        checkTributeDone()
        broadcastGameState()
    }

    public func handleReturnTribute(seatIndex: Int, cards: [Card]) {
        guard phase == .returnTribute, let idx = tributeState.pendingReturns.firstIndex(where: { $0.from == seatIndex && $0.card == nil }) else { return }
        guard cards.count == 1 else { return }
        tributeState.pendingReturns[idx].card = cards[0]
        hands[seatIndex].removeAll { $0.id == cards[0].id }
        let to = tributeState.pendingReturns[idx].to
        hands[to].append(cards[0])
        hands[to] = sortCards(hands[to], level: level)
        checkReturnDone()
        broadcastGameState()
    }

    public func handleUseSkill(seatIndex: Int, skillId: String, targetSeat: Int?) {
        guard isActive, gameMode == .skill, phase == .playing, currentTurn == seatIndex else { return }
        guard let skillIdx = skillCards[seatIndex].firstIndex(where: { $0.id == skillId }) else { return }
        let skill = skillCards[seatIndex][skillIdx]

        let needsTarget: Set<SkillCardType> = [.steal, .discard, .skip]
        if needsTarget.contains(skill.type) {
            guard let ts = targetSeat, ts != seatIndex, !hands[ts].isEmpty else { return }
        }

        guard applySkillEffect(skill.type, user: seatIndex, target: targetSeat) else { return }
        skillCards[seatIndex].remove(at: skillIdx)
        addHistory(.skillUse, "\(players[seatIndex].name) used \(skill.type.displayName)", seatIndex)
        broadcastGameState()
    }

    // MARK: - Bot turn

    public func executeBotTurn(seatIndex: Int) {
        guard isActive, phase == .playing, currentTurn == seatIndex else {
            logger.logTurn("bot_skip", seatIndex: seatIndex, detail: "isActive=\(isActive) phase=\(phase.rawValue) currentTurn=\(currentTurn)")
            return
        }
        guard !hands[seatIndex].isEmpty else {
            logger.logTurn("bot_empty_hand", seatIndex: seatIndex, detail: "advancing turn")
            advanceTurn(); broadcastGameState(); return
        }

        logger.logTurn("bot_turn", seatIndex: seatIndex, detail: "handSize=\(hands[seatIndex].count) lastHand=\(lastHand?.hand.type.rawValue ?? "nil")")

        // Maybe use skill
        if gameMode == .skill, let skill = decideBotSkill(seatIndex) {
            logger.logTurn("bot_skill", seatIndex: seatIndex, detail: "id=\(skill.id)")
            handleUseSkill(seatIndex: seatIndex, skillId: skill.id, targetSeat: skill.targetSeat)
            // Schedule card play after skill
            schedule(after: 1) { [weak self] in self?.executeBotTurn(seatIndex: seatIndex) }
            return
        }

        var ctx = BotGameContext()
        ctx.mySeat = seatIndex
        ctx.winners = winners
        ctx.teammateWon = winners.contains(where: { $0 % 2 == seatIndex % 2 && $0 != seatIndex })
        ctx.opponentCardCounts = (0..<4).map { $0 % 2 != seatIndex % 2 && !winners.contains($0) ? hands[$0].count : -1 }
        
        let bot = Bot(cards: hands[seatIndex], level: level, context: ctx)
        if let move = bot.decideMove(target: lastHand?.hand) {
            // Validate bot's own move; fall back to smallest single if invalid
            let prevTurn = currentTurn
            if getHandType(move, level: level) != nil {
                logger.logTurn("bot_play", seatIndex: seatIndex, detail: "cards=\(move.map { cardDesc($0) }.joined(separator: " "))")
                handlePlayHand(seatIndex: seatIndex, cards: move)
            } else {
                let sorted = sortCards(hands[seatIndex], level: level)
                if let card = sorted.last {
                    logger.logTurn("bot_fallback_single", seatIndex: seatIndex, detail: "card=\(cardDesc(card))")
                    handlePlayHand(seatIndex: seatIndex, cards: [card])
                } else {
                    logger.logTurn("bot_fallback_pass", seatIndex: seatIndex)
                    handlePass(seatIndex: seatIndex)
                }
            }
            // Anti-freeze: if bot's play failed (turn didn't advance), force pass (or play on free turn)
            if currentTurn == prevTurn && phase == .playing {
                logger.logTurn("bot_antifreeze", seatIndex: seatIndex, detail: "turn stuck at \(currentTurn), forcing pass")
                botForcePassOrPlay(seatIndex)
            }
        } else {
            logger.logTurn("bot_pass", seatIndex: seatIndex)
            botForcePassOrPlay(seatIndex)
        }
    }

    /// Bot wants to pass but can't on free turn; force smallest playable card instead
    private func botForcePassOrPlay(_ seatIndex: Int) {
        let isFreeTurn = lastHand?.playerIndex == seatIndex || lastHand == nil
        if isFreeTurn {
            logger.logTurn("bot_free_turn_fallback", seatIndex: seatIndex, detail: "free turn, forcing smallest card")
            let sorted = sortCards(hands[seatIndex], level: level)
            if let card = sorted.last {
                handlePlayHand(seatIndex: seatIndex, cards: [card])
                return
            }
        }
        handlePass(seatIndex: seatIndex)
    }

    // MARK: - Lifecycle

    public func destroy() {
        isActive = false
        for t in pendingTimers { t.cancel() }
        pendingTimers = []
        onBroadcast = nil
    }

    // MARK: - Private

    private func advanceTurn() {
        let prev = currentTurn
        // Skip finished players
        var next = (currentTurn + 1) % 4
        while winners.contains(next) { next = (next + 1) % 4 }
        currentTurn = next
        logger.log("advance_turn_done", detail: "\(prev)→\(next) winners=[\(winners.map(String.init).joined(separator: ","))]")

        // Handle skip effect
        if skipNextTurn[currentTurn] {
            logger.logTurn("skip_effect", seatIndex: currentTurn, detail: "skip triggered, advancing again")
            skipNextTurn[currentTurn] = false
            advanceTurn()
        }
    }

    private func endGame() {
        logger.log("end_game", detail: "winners=[\(winners.map(String.init).joined(separator: ","))]")
        phase = .score
        broadcastGameState()
        if let data = try? JSONEncoder().encode(GameOverData(winners: winners)) {
            onBroadcast?("gameOver", data)
        }
    }

    private func initTributePhase() {
        guard prevWinners.count == 4 else { phase = .playing; currentTurn = activeTeam; return }
        let p1 = prevWinners[0], p2 = prevWinners[1], p3 = prevWinners[2], p4 = prevWinners[3]
        let sameTeam = { (a: Int, b: Int) in a % 2 == b % 2 }

        // Anti-tribute (抗贡): 2 big jokers in losing team
        let isDouble = sameTeam(p1, p2)
        let losingTeam: [Int] = isDouble ? [p3, p4] : [p4]

        // Single win check
        if !isDouble {
            if sameTeam(p1, p4) { // Tie — no tribute
                phase = .playing; currentTurn = p1; return
            }
        }

        let bigJokerCount = losingTeam.reduce(0) { $0 + hands[$1].filter { $0.rank == .bigJoker }.count }
        if bigJokerCount == 2 {
            phase = .playing; currentTurn = p1; return // 抗贡成功
        }

        tributeState = TributeState()
        if isDouble {
            tributeState.pendingTributes = [
                TributeItem(from: p4, to: p1),
                TributeItem(from: p3, to: p2)
            ]
        } else {
            tributeState.pendingTributes = [TributeItem(from: p4, to: p1)]
        }
        phase = .tribute
        processAutoTributes()
    }

    private func processAutoTributes() {
        for item in tributeState.pendingTributes where players[item.from].isBot {
            let hand = hands[item.from]
            let largest = getLargestCard(hand, level: level)
            guard let idx = tributeState.pendingTributes.firstIndex(where: { $0.from == item.from }) else { continue }
            tributeState.pendingTributes[idx].card = largest
            hands[item.from].removeAll { $0.id == largest.id }
            hands[item.to].append(largest)
            hands[item.to] = sortCards(hands[item.to], level: level)
        }
        checkTributeDone()
    }

    private func checkTributeDone() {
        guard tributeState.pendingTributes.allSatisfy({ $0.card != nil }) else { return }
        phase = .returnTribute
        tributeState.pendingReturns = tributeState.pendingTributes.map { TributeItem(from: $0.to, to: $0.from) }

        // Process auto returns for bots
        for item in tributeState.pendingReturns where players[item.from].isBot {
            let hand = hands[item.from]
            let smallest = hand.last!
            if let idx = tributeState.pendingReturns.firstIndex(where: { $0.from == item.from }) {
                tributeState.pendingReturns[idx].card = smallest
                hands[item.from].removeAll { $0.id == smallest.id }
                hands[item.to].append(smallest)
                hands[item.to] = sortCards(hands[item.to], level: level)
            }
        }
        checkReturnDone()
    }

    private func checkReturnDone() {
        guard tributeState.pendingReturns.allSatisfy({ $0.card != nil }) else { return }
        phase = .playing
        // Determine next starter: largest tribute payer goes first
        if let next = tributeState.nextStartPlayer {
            currentTurn = next
        } else {
            currentTurn = prevWinners.first ?? 0
        }
        tributeState = TributeState()
        passCount = 0; lastHand = nil
    }

    private func broadcastGameState() {
        let recentLogs = logger.recentEntries(30)
        for (idx, p) in players.enumerated() {
            guard !p.isBot else { continue }
            let state = GameState(
                phase: phase.rawValue,
                level: level,
                currentTurn: currentTurn,
                ownHand: hands[idx],
                otherHandSizes: hands.map { $0.count },
                lastHand: lastHand,
                roundActions: roundActions,
                winners: winners,
                tributeState: phase == .tribute || phase == .returnTribute ? tributeState : nil,
                teamLevels: teamLevels,
                activeTeam: activeTeam,
                gameMode: gameMode.rawValue,
                skillCards: skillCards[idx],
                skipNextTurn: skipNextTurn,
                newCardIds: newCardIds[idx] ?? [],
                history: history,
                currentRound: currentRound,
                seatIndex: idx,
                playerId: p.id,
                logEntries: recentLogs
            )
            guard let data = try? JSONEncoder().encode(state) else { continue }
            onBroadcast?("gameState", data)
        }

        // Schedule bot turn
        let cp = players[currentTurn]
        let botNames = players.enumerated().compactMap { $1.isBot ? "S\($0)=\($1.name)" : nil }.joined(separator: " ")
        logger.log("broadcast", detail: "turn=\(currentTurn)(\(cp.name)) isBot=\(cp.isBot) phase=\(phase.rawValue) winners=[\(winners.map(String.init).joined(separator: ","))] bots=[\(botNames)]")
        if cp.isBot, phase == .playing, winners.count < 3 {
            let botSeat = currentTurn
            logger.logTurn("schedule_bot", seatIndex: botSeat, detail: "scheduling executeBotTurn in 1.5s")
            schedule(after: 1.5) { [weak self] in
                self?.executeBotTurn(seatIndex: botSeat)
            }
        }
    }

    // MARK: - Skill helpers

    private func dealSkillCards() {
        skillCards = [[], [], [], []]
        var pool: [SkillCard] = []
        for (_, type) in SkillCardType.allCases.enumerated() {
            for j in 0..<2 { pool.append(SkillCard(id: "skill-\(type.rawValue)-\(j)", type: type)) }
        }
        pool.shuffle()
        for i in 0..<4 {
            skillCards[i] = Array(pool[(i * 2)..<(i * 2 + 2)])
        }
    }

    private func applySkillEffect(_ type: SkillCardType, user: Int, target: Int?) -> Bool {
        guard isActive else { return false }
        switch type {
        case .drawTwo:
            let c1 = randomCard(), c2 = randomCard()
            hands[user].append(contentsOf: [c1, c2])
            hands[user] = sortCards(hands[user], level: level)
            trackNewCards(user, [c1.id, c2.id])
        case .steal:
            guard let t = target, !hands[t].isEmpty else { return false }
            let idx = Int(arc4random_uniform(UInt32(hands[t].count)))
            let stolen = hands[t].remove(at: idx)
            hands[user].append(stolen)
            hands[user] = sortCards(hands[user], level: level)
            trackNewCards(user, [stolen.id])
        case .discard:
            guard let t = target, !hands[t].isEmpty else { return false }
            let idx = Int(arc4random_uniform(UInt32(hands[t].count)))
            hands[t].remove(at: idx)
        case .skip:
            guard let t = target else { return false }
            skipNextTurn[t] = true
        case .harvest:
            let active = (0..<4).filter { !hands[$0].isEmpty && !winners.contains($0) }
            for seat in active {
                let c = randomCard()
                hands[seat].append(c)
                hands[seat] = sortCards(hands[seat], level: level)
                trackNewCards(seat, [c.id])
            }
        }
        return true
    }

    private func decideBotSkill(_ seatIndex: Int) -> (id: String, targetSeat: Int?)? {
        let skills = skillCards[seatIndex]
        guard !skills.isEmpty else { return nil }
        let myTeam = seatIndex % 2
        let opponents = (0..<4).filter { $0 % 2 != myTeam && !hands[$0].isEmpty }
        let mySize = hands[seatIndex].count

        for skill in skills {
            switch skill.type {
            case .drawTwo where mySize < 10: return (skill.id, nil)
            case .steal:
                if let t = opponents.max(by: { hands[$0].count < hands[$1].count }), hands[t].count > 5 {
                    return (skill.id, t)
                }
            case .discard:
                if let t = opponents.first(where: { (1...5).contains(hands[$0].count) }) {
                    return (skill.id, t)
                }
            case .skip:
                if let t = opponents.first(where: { hands[$0].count <= 3 }) {
                    return (skill.id, t)
                }
            case .harvest where mySize < 15: return (skill.id, nil)
            default: break
            }
        }

        if Double.random(in: 0...1) < 0.2, let first = skills.first {
            let needsTarget: Set<SkillCardType> = [.steal, .discard, .skip]
            if needsTarget.contains(first.type), let opp = opponents.first {
                return (first.id, opp)
            } else if !needsTarget.contains(first.type) {
                return (first.id, nil)
            }
        }
        return nil
    }

    private func randomCard() -> Card {
        let suits: [Suit] = [.spades, .hearts, .clubs, .diamonds]
        let ranks: [Rank] = [.two, .three, .four, .five, .six, .seven, .eight, .nine, .ten, .jack, .queen, .king, .ace]
        if Double.random(in: 0...1) < 0.05 {
            let isSmall = Double.random(in: 0...1) < 0.5
            return Card(suit: .joker, rank: isSmall ? .smallJoker : .bigJoker, id: "gen-\(UUID().uuidString.prefix(8))")
        }
        let suit = suits.randomElement()!
        let rank = ranks.randomElement()!
        var c = Card(suit: suit, rank: rank, id: "gen-\(UUID().uuidString.prefix(8))")
        if rank.rawValue == level { c.isLevelCard = true; if suit == .hearts { c.isWild = true } }
        return c
    }

    // MARK: - Helpers

    private func schedule(after seconds: Double, block: @escaping () -> Void) {
        let item = DispatchWorkItem { [weak self] in
            guard self?.isActive == true else { return }
            block()
        }
        pendingTimers.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func trackNewCards(_ seat: Int, _ ids: [String]) {
        newCardIds[seat, default: []].append(contentsOf: ids)
        schedule(after: 2) { [weak self] in self?.newCardIds[seat] = [] }
    }

    private func emitError(_ seat: Int, _ msg: String) {
        if let errData = try? JSONEncoder().encode(["message": msg, "seat": String(seat)]) {
                onBroadcast?("error", errData)
            }
    }

    private func addHistory(_ type: HistoryEventType, _ msg: String, _ seat: Int?) {
        let entry = HistoryEntry(
            id: "h\(historyIdCounter)", timestamp: Date().timeIntervalSince1970,
            type: type, playerIndex: seat, playerName: seat.map { players[$0].name }, message: msg
        )
        historyIdCounter += 1
        history.append(entry)
    }
}

// MARK: - Supporting types

public enum GamePhase: String, Codable {
    case waiting, dealing, tribute, returnTribute, playing, score
}

public struct TributeItem: Codable {
    public let from: Int
    public let to: Int
    public var card: Card?

    public init(from: Int, to: Int, card: Card? = nil) {
        self.from = from; self.to = to; self.card = card
    }
}

public struct TributeState: Codable {
    public var pendingTributes: [TributeItem] = []
    public var pendingReturns: [TributeItem] = []
    public var nextStartPlayer: Int?

    public init() {}
}

public struct RoundAction: Codable {
    public let type: String // "play" or "pass"
    public var cards: [Card]?
    public var hand: Hand?

    public init(type: String, cards: [Card]? = nil, hand: Hand? = nil) {
        self.type = type; self.cards = cards; self.hand = hand
    }
}

public struct GameState: Codable {
    public let phase: String
    public let level: Int
    public let currentTurn: Int
    public let ownHand: [Card]
    public let otherHandSizes: [Int]
    public let lastHand: LastHandInfo?
    public let roundActions: [String: RoundAction]
    public let winners: [Int]
    public let tributeState: TributeState?
    public let teamLevels: [String: Int]
    public let activeTeam: Int
    public let gameMode: String
    public let skillCards: [SkillCard]
    public let skipNextTurn: [Bool]
    public let newCardIds: [String]
    public let history: [HistoryEntry]
    public let currentRound: Int
    public let seatIndex: Int
    public let playerId: String
    public let logEntries: [GameLogger.Entry]

    public init(phase: String, level: Int, currentTurn: Int, ownHand: [Card], otherHandSizes: [Int],
                lastHand: (Int, Hand)?, roundActions: [Int: RoundAction], winners: [Int],
                tributeState: TributeState?, teamLevels: [Int: Int], activeTeam: Int,
                gameMode: String, skillCards: [SkillCard], skipNextTurn: [Bool],
                newCardIds: [String], history: [HistoryEntry], currentRound: Int,
                seatIndex: Int, playerId: String, logEntries: [GameLogger.Entry] = []) {
        self.phase = phase
        self.level = level
        self.currentTurn = currentTurn
        self.ownHand = ownHand
        self.otherHandSizes = otherHandSizes
        self.lastHand = lastHand.map { LastHandInfo(playerIndex: $0.0, hand: $0.1) }
        self.roundActions = Dictionary(uniqueKeysWithValues: roundActions.map { (String($0.key), $0.value) })
        self.winners = winners
        self.tributeState = tributeState
        self.teamLevels = Dictionary(uniqueKeysWithValues: teamLevels.map { (String($0.key), $0.value) })
        self.activeTeam = activeTeam
        self.gameMode = gameMode
        self.skillCards = skillCards
        self.skipNextTurn = skipNextTurn
        self.newCardIds = newCardIds
        self.history = history
        self.currentRound = currentRound
        self.seatIndex = seatIndex
        self.playerId = playerId
        self.logEntries = logEntries
    }
}

public struct LastHandInfo: Codable {
    public let playerIndex: Int
    public let hand: Hand
}
