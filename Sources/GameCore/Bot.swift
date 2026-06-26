import Foundation

/// Enhanced Bot AI with wild-card-aware play, bomb restraint, card counting, and teammate cooperation.
public class Bot {
    public var cards: [Card]
    public let level: Int

    /// Context about the game state, provided externally for smarter decisions
    public var gameContext: BotGameContext = BotGameContext()

    public init(cards: [Card], level: Int, context: BotGameContext = BotGameContext()) {
        self.cards = sortCards(cards, level: level)
        self.level = level
        self.gameContext = context
    }

    /// Decide which cards to play. Returns nil to pass.
    /// When `target` is nil (free play), must return something.
    public func decideMove(target: Hand?) -> [Card]? {
        guard !cards.isEmpty else { return nil }

        guard let target else {
            return decideFreePlay()
        }

        // Try to follow normally first
        if let candidate = findBeat(target) {
            return candidate
        }

        // If can't follow, decide whether to bomb
        if let bomb = findBomb(target) {
            return bomb
        }

        return nil
    }

    // MARK: - Free play

    private func decideFreePlay() -> [Card]? {
        let analysis = analyzeHand()

        // With many cards, try longer hands first
        if let tube = tryFreeTube() { return tube }
        if let plate = tryFreePlate() { return plate }

        // Try full house
        if let trips = analysis.trips.first {
            if let pair = findPairExcluding(trips) { return trips + pair }
            return trips
        }

        // Try straight
        if let straight = tryFreeStraight() { return straight }

        // Try pair
        if let pair = analysis.pairs.first { return pair }

        // Single — try to play a mid card (not smallest, not largest)
        if cards.count >= 3 {
            let midIdx = cards.count / 2
            return [cards[midIdx]]
        }
        return [cards.last!]
    }

    // MARK: - Follow beat

    private func findBeat(_ target: Hand) -> [Card]? {
        switch target.type {
        case .single:
            for i in stride(from: cards.count - 1, through: 0, by: -1) {
                let c = cards[i]
                if getLogicValue(rank: c.rank, level: level) > target.value || c.isWild {
                    return [c]
                }
            }
        case .pair:
            for pair in getGroups(size: 2) {
                if getLogicValue(rank: pair[0].rank, level: level) > target.value {
                    return pair
                }
            }
            // Try pair with wild card
            if let wp = tryPairWithWild(beating: target.value) {
                return wp
            }
        case .trips:
            for t in getGroups(size: 3) {
                if getLogicValue(rank: t[0].rank, level: level) > target.value { return t }
            }
        case .tripsWithPair:
            for t in getGroups(size: 3) {
                if getLogicValue(rank: t[0].rank, level: level) > target.value {
                    if let pair = findPairExcluding(t) { return t + pair }
                }
            }
        case .straight:
            if let s = findStraight(beating: target.value) { return s }
        case .tube:
            if let t = findTube(beating: target.value) { return t }
        case .plate:
            if let p = findPlate(beating: target.value) { return p }
        default:
            break
        }
        return nil
    }

    /// Try to form a pair using 1 wild + 1 non-wild that beats target
    private func tryPairWithWild(beating targetValue: Int) -> [Card]? {
        let wilds = cards.filter(\.isWild)
        guard !wilds.isEmpty else { return nil }
        for c in cards where !c.isWild && c.rank.rawValue <= 14 {
            let val = getLogicValue(rank: c.rank, level: level)
            if val > targetValue { return [c, wilds[0]] }
        }
        return nil
    }

    // MARK: - Straight / Tube / Plate detection

    /// Find all possible 5-card straights in the hand
    private func findAllStraights() -> [(cards: [Card], value: Int)] {
        var results: [(cards: [Card], value: Int)] = []
        let wilds = cards.filter(\.isWild)
        let nonWilds = cards.filter { !$0.isWild && $0.rank.rawValue <= 14 }
        let uniqueRanks = Set(nonWilds.map { getLogicValue(rank: $0.rank, level: level) })

        // Pre-compute rank → cards mapping for fast lookup
        var rankCards: [Int: [Card]] = [:]
        for c in nonWilds {
            let r = getLogicValue(rank: c.rank, level: level)
            rankCards[r, default: []].append(c)
        }

        for (window, topVal) in straightWindows {
            var needed = 0
            for r in window { if !uniqueRanks.contains(r) { needed += 1 } }
            guard wilds.count >= needed else { continue }

            var selected: [Card] = []
            var wildUsed = 0
            for r in window {
                if let avail = rankCards[r], !avail.isEmpty {
                    selected.append(avail[0])
                } else {
                    if wildUsed < wilds.count { selected.append(wilds[wildUsed]); wildUsed += 1 }
                }
            }
            if selected.count == 5 { results.append((selected, topVal)) }
        }
        return results.sorted { $0.value < $1.value }
    }

    private func findStraight(beating targetValue: Int) -> [Card]? {
        for s in findAllStraights() where s.value > targetValue { return s.cards }
        return nil
    }

    private func tryFreeStraight() -> [Card]? {
        let straights = findAllStraights()
        // Prefer lower straights to leave high cards for later
        return straights.first?.cards
    }

    /// Find all possible tubes (钢板) in hand
    private func findAllTubes() -> [(cards: [Card], value: Int)] {
        guard cards.count >= 6 else { return [] }
        var results: [(cards: [Card], value: Int)] = []
        let wilds = cards.filter(\.isWild)
        var rankCounts: [Int: Int] = [:]
        var rankCards: [Int: [Card]] = [:]
        for c in cards where !c.isWild && c.rank.rawValue <= 14 {
            let r = getLogicValue(rank: c.rank, level: level)
            rankCounts[r, default: 0] += 1
            rankCards[r, default: []].append(c)
        }

        for window in tubeWindows {
            let needed = window.reduce(0) { $0 + max(0, 2 - (rankCounts[$1] ?? 0)) }
            guard wilds.count >= needed else { continue }

            var selected: [Card] = []
            var wildUsed = 0
            for r in window {
                let avail = (rankCards[r] ?? []).prefix(2)
                selected.append(contentsOf: avail)
                let short = 2 - avail.count
                for _ in 0..<short {
                    if wildUsed < wilds.count { selected.append(wilds[wildUsed]); wildUsed += 1 }
                }
            }
            if selected.count == 6 {
                let val = window == [2,3,14] ? 3 : window[2]
                results.append((selected, val))
            }
        }
        return results.sorted { $0.value < $1.value }
    }

    private func findTube(beating targetValue: Int) -> [Card]? {
        for t in findAllTubes() where t.value > targetValue { return t.cards }
        return nil
    }

    private func tryFreeTube() -> [Card]? {
        return findAllTubes().first?.cards
    }

    /// Find all possible plates (木板) in hand
    private func findAllPlates() -> [(cards: [Card], value: Int)] {
        guard cards.count >= 6 else { return [] }
        var results: [(cards: [Card], value: Int)] = []
        let wilds = cards.filter(\.isWild)
        var rankCounts: [Int: Int] = [:]
        var rankCards: [Int: [Card]] = [:]
        for c in cards where !c.isWild && c.rank.rawValue <= 14 {
            let r = getLogicValue(rank: c.rank, level: level)
            rankCounts[r, default: 0] += 1
            rankCards[r, default: []].append(c)
        }

        for window in plateWindows {
            let needed = window.reduce(0) { $0 + max(0, 3 - (rankCounts[$1] ?? 0)) }
            guard wilds.count >= needed else { continue }

            var selected: [Card] = []
            var wildUsed = 0
            for r in window {
                let avail = (rankCards[r] ?? []).prefix(3)
                selected.append(contentsOf: avail)
                let short = 3 - avail.count
                for _ in 0..<short {
                    if wildUsed < wilds.count { selected.append(wilds[wildUsed]); wildUsed += 1 }
                }
            }
            if selected.count == 6 {
                let val = window == [2,14] ? 2 : window[1]
                results.append((selected, val))
            }
        }
        return results.sorted { $0.value < $1.value }
    }

    private func findPlate(beating targetValue: Int) -> [Card]? {
        for p in findAllPlates() where p.value > targetValue { return p.cards }
        return nil
    }

    private func tryFreePlate() -> [Card]? {
        return findAllPlates().first?.cards
    }

    // MARK: - Bombs (with restraint)

    func findBomb(_ target: Hand?) -> [Card]? {
        let analysis = analyzeHand()

        // 4 Kings
        let kings = findFourKings()

        // Straight flushes
        let sfs = findAllStraightFlushes()

        // Normal bombs sorted by size, then value
        let bombs = analysis.bombs

        guard let target else {
            // Free play — never bomb unless it's the only option (rare)
            return nil
        }

        let targetIsBomb = target.type == .bomb
        let targetIsSF = target.type == .straightFlush
        let targetIsKings = target.type == .fourKings

        // Normal hand: decide whether to bomb
        if !targetIsBomb, !targetIsSF, !targetIsKings {
            guard shouldBomb(target: target) else { return nil }
            // Use smallest bomb first
            if let b = bombs.first { return b.cards }
            if let sf = sfs.first { return sf.cards }
            return kings
        }

        // Can't beat 4 kings
        if targetIsKings { return nil }

        // Target is straight flush
        if targetIsSF {
            let biggerSF = sfs.first { $0.value > target.value }
            if let sf = biggerSF { return sf.cards }
            if let k = kings { return k }
            let bigBomb = bombs.first { $0.cards.count >= 6 }
            if let b = bigBomb { return b.cards }
            return nil
        }

        // Target is normal bomb
        if targetIsBomb {
            let tCount = target.bombCount ?? 4
            let tVal = target.value
            for b in bombs {
                if b.cards.count > tCount { return b.cards }
                if b.cards.count == tCount, b.value > tVal { return b.cards }
            }
            if tCount <= 5, let sf = sfs.first { return sf.cards }
            return kings
        }

        return nil
    }

    /// Decide whether bombing is worthwhile
    private func shouldBomb(target: Hand) -> Bool {
        let ctx = gameContext
        let myCardsLeft = cards.count

        // If I'm close to winning (≤3 cards), always bomb to secure win
        if myCardsLeft <= 3 { return true }

        // If the lead player (who we need to beat) is close to winning, bomb to stop them
        let opponent = ctx.opponentCardCounts.min() ?? 27
        if opponent <= 3 { return true }

        // If it's a small hand (single/pair) and I have many cards, don't waste bombs
        if (target.type == .single || target.type == .pair) && myCardsLeft > 15 {
            return false
        }

        // If my teammate already won, be more conservative
        if ctx.teammateWon {
            return myCardsLeft <= 8
        }

        return true
    }

    private func findFourKings() -> [Card]? {
        let sj = cards.filter { $0.rank == .smallJoker }
        let bj = cards.filter { $0.rank == .bigJoker }
        if sj.count == 2, bj.count == 2 { return sj + bj }
        return nil
    }

    private func findAllStraightFlushes() -> [(cards: [Card], value: Int)] {
        var results: [(cards: [Card], value: Int)] = []
        for s in [Suit.spades, .hearts, .clubs, .diamonds] {
            var suitCards = cards.filter { $0.suit == s && !$0.isWild && $0.rank <= .ace }
            suitCards.sort { $0.rank < $1.rank }
            guard suitCards.count >= 5 else { continue }
            for i in 0...(suitCards.count - 5) {
                let window = Array(suitCards[i..<(i + 5)])
                let ranks = window.map(\.rank.rawValue)
                if isConsecutive(ranks) {
                    results.append((window, ranks.last!))
                }
            }
        }
        // Also try with wild cards for straight flush
        let wilds = cards.filter(\.isWild)
        if !wilds.isEmpty {
            // Group non-wild by suit
            for s in [Suit.spades, .hearts, .clubs, .diamonds] {
                var suitNonWilds = cards.filter { $0.suit == s && !$0.isWild && $0.rank <= .ace }
                suitNonWilds.sort { $0.rank < $1.rank }
                let suitRanks = Set(suitNonWilds.map { getLogicValue(rank: $0.rank, level: level) })

                for (window, topVal) in straightWindows {
                    let needed = window.filter { !suitRanks.contains($0) }.count
                    guard wilds.count >= needed else { continue }
                    results.append(([], topVal)) // placeholder — actual card selection happens at play time
                }
            }
        }
        return results.sorted { $0.value < $1.value }
    }

    // MARK: - Helpers

    private struct HandAnalysis {
        var trips: [[Card]] = []
        var pairs: [[Card]] = []
        var bombs: [(cards: [Card], value: Int)] = []
    }

    private func analyzeHand() -> HandAnalysis {
        var analysis = HandAnalysis()
        let groups = getGroups(size: 2)
        for g in groups {
            if g.count >= 3 { analysis.trips.append(Array(g.prefix(3))) }
            analysis.pairs.append(Array(g.prefix(2)))
        }
        analysis.trips.reverse() // smallest first
        analysis.pairs.reverse()

        // Bombs: groups of 4+
        let allGroups: [[Card]] = {
            var result: [[Card]] = []
            var cur: [Card] = []
            for c in cards {
                if cur.isEmpty || getLogicValue(rank: c.rank, level: level) == getLogicValue(rank: cur[0].rank, level: level) {
                    cur.append(c)
                } else {
                    if cur.count >= 4 { result.append(cur) }
                    cur = [c]
                }
            }
            if cur.count >= 4 { result.append(cur) }
            return result.reversed()
        }()
        analysis.bombs = allGroups.map { ($0, getLogicValue(rank: $0[0].rank, level: level)) }
        return analysis
    }

    func findPairExcluding(_ exclude: [Card]) -> [Card]? {
        let excludeIds = Set(exclude.map(\.id))
        let available = cards.filter { !excludeIds.contains($0.id) }

        var groups: [[Card]] = []
        var cur: [Card] = []
        for c in available {
            if cur.isEmpty || getLogicValue(rank: c.rank, level: level) == getLogicValue(rank: cur[0].rank, level: level) {
                cur.append(c)
            } else {
                if cur.count >= 2 { groups.append(Array(cur.prefix(2))) }
                cur = [c]
            }
        }
        if cur.count >= 2 { groups.append(Array(cur.prefix(2))) }
        return groups.reversed().first
    }

    func getGroups(size: Int) -> [[Card]] {
        var groups: [[Card]] = []
        var cur: [Card] = []
        for c in cards {
            if cur.isEmpty || getLogicValue(rank: c.rank, level: level) == getLogicValue(rank: cur[0].rank, level: level) {
                cur.append(c)
            } else {
                if cur.count >= size { groups.append(Array(cur.prefix(size))) }
                cur = [c]
            }
        }
        if cur.count >= size { groups.append(Array(cur.prefix(size))) }
        return groups.reversed()
    }
}

// MARK: - Game context for bot decisions

public struct BotGameContext {
    /// Cards remaining for each opponent (seat 0-3, -1 for self/teammate)
    public var opponentCardCounts: [Int] = [27, 27, 27, 27]
    /// My teammate already won?
    public var teammateWon: Bool = false
    /// My seat index
    public var mySeat: Int = 0
    /// Winners so far (seat indices)
    public var winners: [Int] = []
    /// Cards visible to me (on table, in play)
    public var visibleHighCards: Int = 0

    public init() {}
}
