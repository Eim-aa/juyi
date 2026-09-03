import Foundation

/// Serial, generation-gated bridge between recognition and synchronous AX.
/// The default worker is private and serial; completion is returned to main.
/// Superseded or cancelled work is discarded without exposing captured text.
final class NativeSelectionCaptureCoordinator {
    typealias Reader = (NativeSelectionTarget) -> NativeSelectionResult
    typealias Scheduler = (@escaping () -> Void) -> Void

    private let lock = NSLock()
    private let reader: Reader?
    private let workScheduler: Scheduler
    private let completionScheduler: Scheduler
    private var generation = 0
    private var activeGeneration: Int?
    private var quiescenceHandlers: [() -> Void] = []

    init(
        reader: Reader? = nil,
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
            guard self?.beginWork(captureGeneration) == true else { return }
            defer { self?.finishWork(captureGeneration) }
            let result: NativeSelectionResult
            if let reader {
                result = reader(target)
            } else {
                let systemClient = SystemNativeSelectionAXClient(
                    cancellationCheck: {
                        [weak self] in self?.isCurrent(captureGeneration) != true
                    },
                    performCriticalEffect: { [weak self] action in
                        guard let self else { return false }
                        return self.performIfCurrent(captureGeneration, action)
                    },
                    performCleanupEffect: { [weak self] action in
                        guard let self else { return false }
                        return self.performIfActive(captureGeneration, action)
                    }
                )
                result = NativeSelectionReader(client: systemClient)
                    .readSelection(for: target)
            }
            guard self?.isCurrent(captureGeneration) == true else { return }
            completionScheduler { [weak self] in
                guard self?.isCurrent(captureGeneration) == true else { return }
                completion(result)
            }
        }
    }

    @discardableResult
    func cancelAll(onQuiesced: (() -> Void)? = nil) -> Bool {
        lock.lock()
        generation += 1
        guard activeGeneration != nil else {
            lock.unlock()
            return true
        }
        if let onQuiesced { quiescenceHandlers.append(onQuiesced) }
        lock.unlock()
        return false
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

    private func beginWork(_ expectedGeneration: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration,
              activeGeneration == nil else { return false }
        activeGeneration = expectedGeneration
        return true
    }

    private func finishWork(_ expectedGeneration: Int) {
        lock.lock()
        guard activeGeneration == expectedGeneration else {
            lock.unlock()
            return
        }
        activeGeneration = nil
        let handlers = quiescenceHandlers
        quiescenceHandlers.removeAll()
        lock.unlock()
        guard !handlers.isEmpty else { return }
        completionScheduler {
            for handler in handlers { handler() }
        }
    }

    private func performIfCurrent(
        _ expectedGeneration: Int,
        _ action: () -> Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration else { return false }
        return action()
    }

    /// Cleanup remains permitted for the in-flight reader after cancellation.
    /// The owner lease is retained until `finishWork`, so the reader can restore
    /// only the exact pasteboard state it owns before revocation is retried.
    private func performIfActive(
        _ expectedGeneration: Int,
        _ action: () -> Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == expectedGeneration else { return false }
        return action()
    }
}
