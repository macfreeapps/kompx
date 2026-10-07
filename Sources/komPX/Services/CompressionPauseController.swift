import Foundation

final class CompressionPauseController: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false

    func reset() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    func pause() {
        condition.lock()
        paused = true
        condition.unlock()
    }

    func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    func waitIfPaused(cancellationCheck: @escaping @Sendable () -> Bool) -> Bool {
        condition.lock()
        while paused && !cancellationCheck() {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.25))
        }
        let shouldContinue = !cancellationCheck()
        condition.unlock()
        return shouldContinue
    }
}
