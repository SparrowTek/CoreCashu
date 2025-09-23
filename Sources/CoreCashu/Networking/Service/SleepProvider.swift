import Foundation

protocol SleepProviding: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

struct TaskSleeper: SleepProviding {
    func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

