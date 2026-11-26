import Foundation

public struct ScheduleReminder: Codable, Equatable, Sendable {
    public let scheduledAt: Date
    public let checkedAt: Date
    public let scope: ScheduleScope
    public let updateCount: Int

    static let window: TimeInterval = 30 * 60
    static let recheckInterval: TimeInterval = 15 * 60
}

public struct ScheduleTick: Sendable {
    public let outcome: RunOutcome?
    public let reminder: ScheduleReminder?
    public let shouldNotify: Bool

    init(outcome: RunOutcome? = nil, reminder: ScheduleReminder? = nil, shouldNotify: Bool = false) {
        self.outcome = outcome
        self.reminder = reminder
        self.shouldNotify = shouldNotify
    }
}

extension EngineClient {
    public func scheduleNeedsService() throws -> Bool {
        let config = try EngineConfiguration(url: configURL)
        let state = NativeState(directory: stateDirectory)
        let now = Date()
        guard config.automaticRuns, config.scheduleScope != .brew || Self.hasHomebrew,
              let slot = try state.latestScheduleSlot(at: now, config: config) else { return false }
        if now.timeIntervalSince(slot) < ScheduleReminder.window { return true }
        guard let previous = try state.scheduleReminder(), previous.scheduledAt == slot, previous.scope == config.scheduleScope else {
            return configurationPredates(slot)
        }
        return now.timeIntervalSince(previous.checkedAt) >= ScheduleReminder.recheckInterval
    }

    public func pendingSchedule() throws -> ScheduleReminder? {
        let config = try EngineConfiguration(url: configURL)
        let state = NativeState(directory: stateDirectory)
        guard config.automaticRuns, config.scheduleScope != .brew || Self.hasHomebrew,
              let previous = try state.scheduleReminder(), previous.updateCount > 0,
              previous.scope == config.scheduleScope,
              try state.latestScheduleSlot(at: Date(), config: config) == previous.scheduledAt else { return nil }
        return previous
    }

    public func runMissedSchedule(expectedAt: Date? = nil) async throws -> RunOutcome? {
        guard let reminder = try pendingSchedule(), expectedAt == nil || expectedAt == reminder.scheduledAt else { return nil }
        return try await runAutomatically(scheduledFor: reminder.scheduledAt)
    }

    public func serviceSchedule() async throws -> ScheduleTick {
        try await serviceSchedule(clock: Date.init) { [configURL, stateDirectory] scope in
            let catalog = try UpdateCatalog(configURL: configURL, stateDirectory: stateDirectory)
            let candidates = try catalog.scheduledCheckItems(scope: scope)
            let pending = PendingScheduledUpdates()
            try await catalog.check(candidates) { await pending.record($0) }
            return await pending.count
        }
    }

    func serviceSchedule(clock: @Sendable () -> Date,
                         findPending: @Sendable (ScheduleScope) async throws -> Int) async throws -> ScheduleTick {
        let config = try EngineConfiguration(url: configURL)
        let state = NativeState(directory: stateDirectory)
        let now = clock()
        guard config.automaticRuns, config.scheduleScope != .brew || Self.hasHomebrew,
              let slot = try state.latestScheduleSlot(at: now, config: config) else { return ScheduleTick() }

        if now.timeIntervalSince(slot) < ScheduleReminder.window {
            return ScheduleTick(outcome: try await runAutomatically(scheduledFor: slot))
        }

        let previous = try state.scheduleReminder()
        if let previous, previous.scheduledAt == slot, previous.scope == config.scheduleScope {
            if now.timeIntervalSince(previous.checkedAt) < ScheduleReminder.recheckInterval {
                return ScheduleTick(reminder: previous.updateCount > 0 ? previous : nil)
            }
        } else if !configurationPredates(slot) {
            return ScheduleTick()
        }

        let count = try await findPending(config.scheduleScope)
        let checkedAt = clock()
        let reminder = ScheduleReminder(scheduledAt: slot, checkedAt: checkedAt, scope: config.scheduleScope, updateCount: count)
        let freshConfig = try EngineConfiguration(url: configURL)
        return try state.withLock {
            guard freshConfig.automaticRuns, freshConfig.scheduleScope == config.scheduleScope,
                  try state.latestScheduleSlot(at: checkedAt, config: freshConfig) == slot else { return ScheduleTick() }
            let saved = try state.scheduleReminder()
            let alreadyNotified = saved?.scheduledAt == slot && saved?.scope == config.scheduleScope && (saved?.updateCount ?? 0) > 0
            try state.saveScheduleReminder(reminder)
            return ScheduleTick(reminder: count > 0 ? reminder : nil, shouldNotify: count > 0 && !alreadyNotified)
        }
    }

    private func configurationPredates(_ slot: Date) -> Bool {
        let changed = try? configURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return changed.map { $0 <= slot } ?? true
    }
}

private actor PendingScheduledUpdates {
    private(set) var count = 0

    func record(_ item: UpdateItem) {
        if item.action == .install && (item.status == .available || item.status == .newerRelease) { count += 1 }
    }
}
