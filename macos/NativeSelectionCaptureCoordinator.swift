import Foundation

/// Serial, generation-gated bridge between recognition and synchronous AX.
/// The default worker is private and serial; completion is returned to main.
/// Superseded or cancelled work is discarded without exposing captured text.
final class NativeSelectionCaptureCoordinator {
    typealias Reader = (NativeSelectionTarget) -> NativeSelectionResult
    typealias Scheduler = (@escaping () -> Void) -> Void

    private let lock = NSLock()
    private let reader: Reader
    private let workScheduler: Scheduler
    private let completionScheduler: Scheduler
    private var generation = 0

    init(
        reader: @escaping Reader = { target in
            NativeSelectionReader().readSelection(for: target)
        },
        workScheduler: Scheduler? = nil,
        completionScheduler: Scheduler? = nil
    ) {
        let worker = DispatchQueue(
            label: "io.github.Eim-aa.Juyi.native-selection",
            qos: .userInitiated
        )
        self.reader = reader
        self.workScheduler = workScheduler ?? { action in
            worker.async(execute: DispatchWorkItem(block: action))
        }
        self.completionScheduler = completionScheduler ?? { action in
            DispatchQueue.main.async(execute: DispatchWorkItem(block: action))
        }
    }

    func capture(
        target: NativeSelectionTarget,
        completion: @escaping (NativeSelectionResult) -> Void
    ) {
        let captureGeneration = advanceGeneration()
        let reader = self.reader
        let completionScheduler = self.completionScheduler
        workScheduler { [weak self] in
            guard self?.isCurrent(captureGeneration) == true else { return }
            let result = reader(target)
            guard self?.isCurrent(captureGeneration) == true else { return }
            completionScheduler { [weak self] in
                guard self?.isCurrent(captureGeneration) == true else { return }
                completion(result)
            }
        }
    }

    func cancelAll() {
        _ = advanceGeneration()
    }

    private func advanceGeneration() -> Int {
        lock.lock()
        generation += 1
        let value = generation
        lock.unlock()
        return value
    }

    private func isCurrent(_ expectedGeneration: Int) -> Bool {
        lock.lock()
        let current = generation == expectedGeneration
        lock.unlock()
        return current
    }
}
