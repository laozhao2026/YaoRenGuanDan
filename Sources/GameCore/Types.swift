import Foundation

// MARK: - Suit
public enum Suit: Int, Codable, CaseIterable, CustomStringConvertible {
    case spades = 0
    case hearts = 1
    case clubs = 2
    case diamonds = 3
    case joker = 4

    public var description: String {
        switch self {
        case .spades:   "♠"
        case .hearts:   "♥"
        case .clubs:    "♣"
        case .diamonds: "♦"
        case .joker:    "🃏"
        }
    }

    public var symbol: String { description }
}

// MARK: - Rank
public enum Rank: Int, Codable, CaseIterable, Comparable {
    case two = 2, three, four, five, six, seven, eight, nine, ten
    case jack = 11, queen = 12, king = 13, ace = 14
    case smallJoker = 15, bigJoker = 16

    public static func < (lhs: Rank, rhs: Rank) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var display: String {
        switch self {
        case .two:   "2"; case .three: "3"; case .four: "4"
        case .five:  "5"; case .six:   "6"; case .seven: "7"
        case .eight: "8"; case .nine:  "9"; case .ten:  "10"
        case .jack:  "J"; case .queen: "Q"; case .king:  "K"
        case .ace:   "A"
        case .smallJoker: "小王"; case .bigJoker: "大王"
        }
    }
}

// MARK: - Card
public struct Card: Identifiable, Codable, Equatable, Hashable {
    public let suit: Suit
    public let rank: Rank
    public let id: String
    public var isLevelCard: Bool = false
    public var isWild: Bool = false

    public init(suit: Suit, rank: Rank, id: String, isLevelCard: Bool = false, isWild: Bool = false) {
        self.suit = suit
        self.rank = rank
        self.id = id
        self.isLevelCard = isLevelCard
        self.isWild = isWild
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: Card, rhs: Card) -> Bool { lhs.id == rhs.id }
}

// MARK: - HandType
public enum HandType: String, Codable {
    case single = "Single"
    case pair = "Pair"
    case trips = "Trips"
    case tripsWithPair = "TripsWithPair"
    case straight = "Straight"
    case tube = "Tube"
    case plate = "Plate"
    case bomb = "Bomb"
    case straightFlush = "StraightFlush"
    case fourKings = "FourKings"
}

// MARK: - Hand
public struct Hand: Codable {
    public let type: HandType
    public let cards: [Card]
    public let value: Int
    public var bombCount: Int?

    public init(type: HandType, cards: [Card], value: Int, bombCount: Int? = nil) {
        self.type = type
        self.cards = cards
        self.value = value
        self.bombCount = bombCount
    }
}

// MARK: - GameMode
public enum GameMode: String, Codable {
    case normal = "Normal"
    case skill = "Skill"
}

// MARK: - SkillCardType
public enum SkillCardType: String, Codable, CaseIterable {
    case drawTwo = "DrawTwo"
    case steal = "Steal"
    case discard = "Discard"
    case skip = "Skip"
    case harvest = "Harvest"

    public var displayName: String {
        switch self {
        case .drawTwo:  "无中生有"
        case .steal:    "顺手牵羊"
        case .discard:  "过河拆桥"
        case .skip:     "乐不思蜀"
        case .harvest:  "五谷丰登"
        }
    }
}

public struct SkillCard: Identifiable, Codable {
    public let id: String
    public let type: SkillCardType

    public init(id: String, type: SkillCardType) {
        self.id = id
        self.type = type
    }
}

// MARK: - History
public enum HistoryEventType: String, Codable {
    case gameStart = "GameStart"
    case phaseChange = "PhaseChange"
    case play = "Play"
    case pass = "Pass"
    case tribute = "Tribute"
    case returnTribute = "ReturnTribute"
    case skillUse = "SkillUse"
    case roundEnd = "RoundEnd"
    case playerFinish = "PlayerFinish"
    case gameEnd = "GameEnd"
    case levelUp = "LevelUp"
}

public struct HistoryEntry: Identifiable, Codable {
    public let id: String
    public let timestamp: TimeInterval
    public let type: HistoryEventType
    public let playerIndex: Int?
    public let playerName: String?
    public let message: String

    public init(id: String, timestamp: TimeInterval, type: HistoryEventType, playerIndex: Int? = nil, playerName: String? = nil, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.playerIndex = playerIndex
        self.playerName = playerName
        self.message = message
    }
}
