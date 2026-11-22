import Foundation

public struct UpdateCheckCache: Codable, Sendable {
    public static let automaticCooldown: TimeInterval = 3600

    public let attemptedAt: Date
    public let checkedAt: Date?
    private let rows: [Row]

    public init(attemptedAt: Date, checkedAt: Date?, items: [UpdateItem]) {
        self.attemptedAt = attemptedAt
        self.checkedAt = checkedAt
        rows = items.map(Row.init)
    }

    public func allowsAutomaticCheck(at now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(attemptedAt)
        return elapsed < 0 || elapsed >= Self.automaticCooldown
    }

    /// Keep live paths, running state, exclusions and link destinations.
    public func restore(into inventory: [UpdateItem]) -> [UpdateItem] {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        return inventory.map { item in
            guard item.status == .readyToCheck, let cached = byID[item.id],
                  cached.version == item.installedVersion, cached.repository == item.repository?.name else { return item }
            return cached.restore(into: item)
        }
    }

    private struct Row: Codable {
        enum Action: String, Codable { case original, none, install, openApp }
        let id: String
        let version: String
        let repository: String?
        let status: UpdateItem.Status
        let offeredVersion: String
        let detail: String
        let action: Action

        init(_ item: UpdateItem) {
            id = item.id
            version = item.installedVersion
            repository = item.repository?.name
            status = item.status
            offeredVersion = item.offeredVersion
            detail = item.detail
            switch item.action {
            case .install: action = .install
            case .openApp: action = .openApp
            case nil: action = .none
            default: action = .original
            }
        }

        func restore(into item: UpdateItem) -> UpdateItem {
            var result = item
            result.status = status
            result.offeredVersion = offeredVersion
            result.detail = detail
            switch action {
            case .original: break
            case .none: result.action = nil
            case .install: result.action = item.path == nil ? item.action : .install
            case .openApp: result.action = item.path == nil ? item.action : .openApp
            }
            return result
        }
    }
}
