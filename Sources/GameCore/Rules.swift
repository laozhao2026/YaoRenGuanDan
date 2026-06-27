import Foundation

/// Get logical value for sorting/comparison. Level cards > Ace but < Jokers.
public func getLogicValue(rank: Rank, level: Int) -> Int {
    switch rank {
    case .smallJoker: 20
    case .bigJoker:   21
    case _ where rank.rawValue == level: 19
    case .ace: 14
    default: rank.rawValue
    }
}

/// Sort cards descending by logical value, then suit
public func sortCards(_ cards: [Card], level: Int) -> [Card] {
    cards.sorted { a, b in
        let va = getLogicValue(rank: a.rank, level: level)
        let vb = getLogicValue(rank: b.rank, level: level)
        if va != vb { return va > vb }
        return a.suit.rawValue > b.suit.rawValue
    }
}

/// Check if values form a consecutive sequence
public func isConsecutive(_ values: [Int]) -> Bool {
    guard values.count >= 2 else { return false }
    let sorted = values.sorted()
    if sorted.last == 14, sorted.first == 2, sorted.count == 5,
       sorted == [2, 3, 4, 5, 14] { return true }
    for i in 0..<(sorted.count - 1) {
        if sorted[i + 1] != sorted[i] + 1 { return false }
    }
    return true
}

/// All possible 5-card straight windows: [low...low+4], plus A-2-3-4-5
internal let straightWindows: [(ranks: [Int], topValue: Int)] = {
    var w: [([Int], Int)] = []
    for low in 2...10 { w.append((Array(low...(low+4)), low+4)) }
    w.append(([2,3,4,5,14], 5)) // A-2-3-4-5
    return w
}()

/// All possible tube windows (3 consecutive pairs): low, low+1, low+2
internal let tubeWindows: [[Int]] = {
    var w: [[Int]] = []
    for low in 2...12 { w.append([low, low+1, low+2]) }
    w.append([2,3,14]) // Q-K-A? Actually A-2-3: ranks 14,2,3 → treat as 1,2,3
    return w
}()

/// All possible plate windows (2 consecutive triples): low, low+1
internal let plateWindows: [[Int]] = {
    var w: [[Int]] = []
    for low in 2...13 { w.append([low, low+1]) }
    w.append([2,14]) // K-A? Actually A-2: 14,2
    return w
}()

// MARK: - Hand type detection

/// Get non-wild rank counts (raw 2-14 only), plus wild count
private func analyzeCards(_ cards: [Card], level: Int) -> (counts: [Int: Int], wildCount: Int, nonWildSuits: [Suit]) {
    var counts = [Int: Int]()
    var wildCount = 0
    var suits = [Suit]()
    for c in cards {
        if c.isWild { wildCount += 1 }
        else {
            let v = getLogicValue(rank: c.rank, level: level)
            counts[v, default: 0] += 1
            if c.rank.rawValue <= 14 { suits.append(c.suit) }
        }
    }
    return (counts, wildCount, suits)
}

/// Try forming a straight (or straight flush) with wild cards
private func tryStraight(cards: [Card], level: Int, wildCount: Int, counts: [Int: Int], suits: [Suit]) -> Hand? {
    guard cards.count == 5 else { return nil }
    let sorted = sortCards(cards, level: level)

    // Non-wild ranks (raw values, unique)
    let nonWildRanks = counts.keys.map { Int($0) }
    let uniqueRanks = Set(nonWildRanks)
    // Suits of non-wild cards
    let nonWildSuits = suits
    let sameSuit = !nonWildSuits.isEmpty && Set(nonWildSuits).count == 1

    var bestVal = -1
    var bestIsSF = false

    for (window, topVal) in straightWindows {
        let covered = window.filter { uniqueRanks.contains($0) }.count
        let needed = max(0, 5 - covered)
        guard wildCount >= needed else { continue }

        // Straight: always valid
        if topVal > bestVal { bestVal = topVal; bestIsSF = false }

        // Straight flush: all non-wilds same suit
        if sameSuit && nonWildSuits.first != nil && topVal >= bestVal {
            bestVal = topVal; bestIsSF = true
        }
    }

    if bestVal == -1 { return nil }

    if bestIsSF {
        return Hand(type: .straightFlush, cards: sorted, value: bestVal, bombCount: 5)
    }
    return Hand(type: .straight, cards: sorted, value: bestVal)
}

/// Try forming a tube (钢板) with wild cards — 3 consecutive pairs, 6 cards
private func tryTube(cards: [Card], level: Int, wildCount: Int, counts: [Int: Int]) -> Hand? {
    guard cards.count == 6 else { return nil }
    let sorted = sortCards(cards, level: level)

    for window in tubeWindows {
        let needed = window.reduce(0) { $0 + max(0, 2 - (counts[$1] ?? 0)) }
        guard wildCount >= needed else { continue }
        // Use the top rank as value (A-2-3 → value=3)
        _ = window[1] == 14 ? 3 : window[2] // A-2-3 special case
        let val = window == [2,3,14] ? 3 : window[2]
        return Hand(type: .tube, cards: sorted, value: val)
    }
    return nil
}

/// Try forming a plate (木板) with wild cards — 2 consecutive triples, 6 cards
private func tryPlate(cards: [Card], level: Int, wildCount: Int, counts: [Int: Int]) -> Hand? {
    guard cards.count == 6 else { return nil }
    let sorted = sortCards(cards, level: level)

    for window in plateWindows {
        let needed = window.reduce(0) { $0 + max(0, 3 - (counts[$1] ?? 0)) }
        guard wildCount >= needed else { continue }
        let val = window == [2,14] ? 2 : window[1]
        return Hand(type: .plate, cards: sorted, value: val)
    }
    return nil
}

/// Main function to detect hand type from selected cards
public func getHandType(_ cards: [Card], level: Int) -> Hand? {
    guard !cards.isEmpty else { return nil }
    let len = cards.count
    let sorted = sortCards(cards, level: level)
    let (counts, wildCount, suits) = analyzeCards(cards, level: level)
    let uniqueValues = counts.keys.sorted(by: >)
    let maxCount = counts.values.max() ?? 0

    // 1. Four Kings (Sky Bomb)
    if len == 4 {
        let sj = cards.filter { $0.rank == .smallJoker }.count
        let bj = cards.filter { $0.rank == .bigJoker }.count
        if sj == 2, bj == 2 {
            return Hand(type: .fourKings, cards: sorted, value: 999)
        }
    }

    // 2. Single
    if len == 1 {
        let val = cards[0].isWild ? 19 : getLogicValue(rank: cards[0].rank, level: level)
        return Hand(type: .single, cards: sorted, value: val)
    }

    // 3. Pair
    if len == 2 {
        if wildCount == 2 {
            return Hand(type: .pair, cards: sorted, value: 19)
        }
        if wildCount == 1 {
            let nonWild = cards.first { !$0.isWild }!
            if nonWild.rank.rawValue > Rank.ace.rawValue { return nil }
            return Hand(type: .pair, cards: sorted, value: getLogicValue(rank: nonWild.rank, level: level))
        }
        if uniqueValues.count == 1 {
            return Hand(type: .pair, cards: sorted, value: uniqueValues[0])
        }
    }

    // 4. Trips
    if len == 3 {
        if wildCount == 3 {
            return Hand(type: .trips, cards: sorted, value: 19)
        }
        if uniqueValues.count == 1, (counts[uniqueValues[0]]! + wildCount) == 3 {
            if uniqueValues[0] > 19 { return nil }
            return Hand(type: .trips, cards: sorted, value: uniqueValues[0])
        }
    }

    // 5. Full House or 5-Bomb
    if len == 5 {
        // 5-card bomb
        if maxCount + wildCount == 5 {
            return Hand(type: .bomb, cards: sorted, value: uniqueValues.first ?? 19, bombCount: 5)
        }
        // Full house
        for tVal in uniqueValues where tVal <= 19 {
            let tCount = counts[tVal]!
            let wildsForTrips = max(0, 3 - tCount)
            guard wildCount >= wildsForTrips else { continue }
            let remWilds = wildCount - wildsForTrips
            let others = uniqueValues.filter { $0 != tVal }
            if others.isEmpty { continue }
            if others.count == 1 {
                let pVal = others[0]
                guard pVal <= 19 else { continue }
                if (counts[pVal]! + remWilds) >= 2 {
                    return Hand(type: .tripsWithPair, cards: sorted, value: tVal)
                }
            }
        }
    }

    // 6. Straight / Straight Flush (5 cards) — now with wild card support
    if len == 5 {
        if let result = tryStraight(cards: cards, level: level, wildCount: wildCount, counts: counts, suits: suits) {
            return result
        }
    }

    // 7. Bomb (4+ cards)
    if len >= 4 {
        if maxCount + wildCount == len, uniqueValues.count <= 1 {
            let val = uniqueValues.first ?? 19
            if val <= 19 {
                return Hand(type: .bomb, cards: sorted, value: val, bombCount: len)
            }
        }
    }

    // 8. Tube / Plate (6 cards) — now with wild card support
    if len == 6 {
        if let result = tryTube(cards: cards, level: level, wildCount: wildCount, counts: counts) { return result }
        if let result = tryPlate(cards: cards, level: level, wildCount: wildCount, counts: counts) { return result }
    }

    return nil
}

/// Compare two hands. Returns positive if handA > handB, 0 if can't compare, negative if handA < handB.
public func compareHands(_ handA: Hand, _ handB: Hand) -> Int {
    if handA.type == .fourKings { return 1 }
    if handB.type == .fourKings { return -1 }

    let isBombA = handA.type == .bomb || handA.type == .straightFlush
    let isBombB = handB.type == .bomb || handB.type == .straightFlush

    if isBombA && !isBombB { return 1 }
    if !isBombA && isBombB { return -1 }

    if isBombA && isBombB {
        func score(_ h: Hand) -> Double {
            if h.type == .straightFlush { return 5.5 }
            return Double(h.bombCount ?? 4)
        }
        let sA = score(handA), sB = score(handB)
        if sA != sB { return sA < sB ? -1 : 1 }
        return handA.value < handB.value ? -1 : (handA.value > handB.value ? 1 : 0)
    }

    guard handA.type == handB.type else { return 0 }
    guard handA.cards.count == handB.cards.count else { return 0 }
    return handA.value < handB.value ? -1 : (handA.value > handB.value ? 1 : 0)
}

/// Get the largest card by logical value
public func getLargestCard(_ cards: [Card], level: Int) -> Card {
    let sorted = sortCards(cards, level: level)
    return sorted.first!
}

/// Human-readable hand description
public func handDescription(_ hand: Hand) -> String {
    let names: [HandType: String] = [
        .single: "单张", .pair: "对子", .trips: "三张",
        .tripsWithPair: "三带二", .straight: "顺子",
        .tube: "钢板", .plate: "木板",
        .bomb: "炸弹", .straightFlush: "同花顺", .fourKings: "天王炸"
    ]
    var desc = names[hand.type] ?? hand.type.rawValue
    if hand.type == .bomb, let bc = hand.bombCount {
        desc += " (\(bc)张)"
    }
    return desc
}

/// Short card description for logging: "♠A", "♥2", "🃏小王"
public func cardDesc(_ card: Card) -> String {
    return "\(card.suit.symbol)\(card.rank.display)"
}
