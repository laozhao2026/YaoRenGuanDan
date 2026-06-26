import Foundation

/// Create a full 108-card double deck
public func createDeck() -> [Card] {
    var cards: [Card] = []
    let suits: [Suit] = [.spades, .hearts, .clubs, .diamonds]
    let ranks: [Rank] = [
        .two, .three, .four, .five, .six, .seven,
        .eight, .nine, .ten, .jack, .queen, .king, .ace
    ]

    for deckIdx in 0..<2 {
        for suit in suits {
            for rank in ranks {
                cards.append(Card(
                    suit: suit, rank: rank,
                    id: "\(suit.rawValue)-\(rank.rawValue)-\(deckIdx)"
                ))
            }
        }
        cards.append(Card(suit: .joker, rank: .smallJoker, id: "joker-small-\(deckIdx)"))
        cards.append(Card(suit: .joker, rank: .bigJoker, id: "joker-big-\(deckIdx)"))
    }
    return cards
}

/// Fisher-Yates shuffle
public func shuffleDeck(_ cards: [Card]) -> [Card] {
    var result = cards
    for i in stride(from: result.count - 1, through: 1, by: -1) {
        let j = Int(arc4random_uniform(UInt32(i + 1)))
        result.swapAt(i, j)
    }
    return result
}

/// Mark level cards and wild cards based on the current level
public func updateCardProperties(_ cards: [Card], level: Int) -> [Card] {
    cards.map { card in
        var c = card
        c.isLevelCard = card.rank.rawValue == level
        c.isWild = c.isLevelCard && card.suit == .hearts
        return c
    }
}
