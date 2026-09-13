import Foundation

final class ManualTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 0)

    var now: Date {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.date
    }

    func advance(by interval: TimeInterval) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.date.addTimeInterval(interval)
    }
}
