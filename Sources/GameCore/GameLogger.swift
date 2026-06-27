import Foundation

/// 游戏全程调试日志，记录所有关键事件用于问题排查
public final class GameLogger: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        public let timestamp: String
        public let event: String
        public let detail: String
        public let seatIndex: Int?
    }

    public private(set) var entries: [Entry] = []
    public var onNewEntry: ((Entry) -> Void)?
    private let maxEntries = 500
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.guandan.gamelogger")

    public init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
    }

    public func log(_ event: String, detail: String = "", seatIndex: Int? = nil) {
        let entry = Entry(
            timestamp: dateFormatter.string(from: Date()),
            event: event,
            detail: detail,
            seatIndex: seatIndex
        )
        queue.async { [weak self] in
            guard let self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
            DispatchQueue.main.async {
                self.onNewEntry?(entry)
            }
        }
        // Also print to console for Xcode debugging
        let seatStr = seatIndex.map { "[S\($0)]" } ?? ""
        print("[GameLog] \(entry.timestamp) \(seatStr) [\(event)] \(detail)")
    }

    public func logTurn(_ event: String, seatIndex: Int, detail: String = "") {
        log(event, detail: detail, seatIndex: seatIndex)
    }

    public func recentEntries(_ count: Int = 50) -> [Entry] {
        queue.sync {
            Array(entries.suffix(count))
        }
    }

    public func flush() {
        queue.async { [weak self] in
            self?.entries.removeAll()
        }
    }
}
