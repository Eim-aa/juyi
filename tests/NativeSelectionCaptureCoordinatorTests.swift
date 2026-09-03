import Foundation

@main
@MainActor
enum NativeSelectionCaptureCoordinatorTests {
    private final class ManualScheduler {
        private var actions: [() -> Void] = []

        func schedule(_ action: @escaping () -> Void) {
            actions.append(action)
        }

        var count: Int { actions.count }

        func run(_ index: Int) {
            actions[index]()
        }
    }

    private static let firstTarget = NativeSelectionTarget(
        processIdentifier: 200,
        launchDate: Date(timeIntervalSinceReferenceDate: 1_000),
        bundleIdentifier: "com.example.first"
    )
    private static let secondTarget = NativeSelectionTarget(
        processIdentifier: 300,
        launchDate: Date(timeIntervalSinceReferenceDate: 1_100),
        bundleIdentifier: "com.example.second"
    )
    private static var passed = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
        passed += 1
    }

    private static func testCaptureIsDeferredAndLatestWins() {
        let worker = ManualScheduler()
        let completion = ManualScheduler()
        var reads: [NativeSelectionTarget] = []
        var results: [NativeSelectionResult] = []
        let coordinator = NativeSelectionCaptureCoordinator(
            reader: { target in
                reads.append(target)
                return .success(
                    text: target.bundleIdentifier ?? "",
                    didTruncate: false
                )
            },
            workScheduler: worker.schedule,
            completionScheduler: completion.schedule
        )

        coordinator.capture(target: firstTarget) { results.append($0) }
        coordinator.capture(target: secondTarget) { results.append($0) }
        expect(reads.isEmpty, "AX reader never runs synchronously in recognition callback")
        expect(worker.count == 2, "both captures are queued on the worker")

        worker.run(0)
        worker.run(1)
        expect(reads == [secondTarget], "superseded queued work never reads AX")
        expect(completion.count == 1, "only current result reaches completion scheduler")
        completion.run(0)
        expect(
            results == [
                .success(text: "com.example.second", didTruncate: false)
            ],
            "latest in-memory result is delivered"
        )
    }

    private static func testCancellationDropsQueuedText() {
        let worker = ManualScheduler()
        let completion = ManualScheduler()
        var results: [NativeSelectionResult] = []
        var coordinator: NativeSelectionCaptureCoordinator!
        coordinator = NativeSelectionCaptureCoordinator(
            reader: { _ in
                coordinator.cancelAll()
                return .success(text: "sensitive", didTruncate: false)
            },
            workScheduler: worker.schedule,
            completionScheduler: completion.schedule
        )
        coordinator.capture(target: firstTarget) { results.append($0) }
        worker.run(0)
        expect(completion.count == 0, "cancel during AX never queues captured text on main")
        expect(results.isEmpty, "stop/pause/revocation cancellation drops stale text")
    }

    private static func testCancellationDropsAlreadyScheduledCompletion() {
        let worker = ManualScheduler()
        let completion = ManualScheduler()
        var results: [NativeSelectionResult] = []
        let coordinator = NativeSelectionCaptureCoordinator(
            reader: { _ in
                .success(text: "sensitive", didTruncate: false)
            },
            workScheduler: worker.schedule,
            completionScheduler: completion.schedule
        )

        coordinator.capture(target: firstTarget) { results.append($0) }
        worker.run(0)
        expect(completion.count == 1, "current AX result may queue a main completion")
        coordinator.cancelAll()
        completion.run(0)
        expect(results.isEmpty, "cancellation invalidates an already queued completion")
    }

    private static func testCancellationReportsQuiescenceAfterActiveReaderFinishes() {
        let worker = ManualScheduler()
        let completion = ManualScheduler()
        var coordinator: NativeSelectionCaptureCoordinator!
        var cancelReportedIdle: Bool?
        var quiesced = false
        coordinator = NativeSelectionCaptureCoordinator(
            reader: { _ in
                cancelReportedIdle = coordinator.cancelAll {
                    quiesced = true
                }
                return .cancelled
            },
            workScheduler: worker.schedule,
            completionScheduler: completion.schedule
        )

        coordinator.capture(target: firstTarget) { _ in }
        worker.run(0)
        expect(
            cancelReportedIdle == false,
            "active cancellation keeps owner revocation pending"
        )
        expect(!quiesced, "quiescence callback is not run inside the reader")
        expect(completion.count == 1, "reader completion schedules one quiescence callback")
        completion.run(0)
        expect(quiesced, "quiescence callback runs after cleanup-capable reader exits")
        expect(coordinator.cancelAll(), "subsequent cancellation is immediately quiescent")
    }

    static func main() {
        testCaptureIsDeferredAndLatestWins()
        testCancellationDropsQueuedText()
        testCancellationDropsAlreadyScheduledCompletion()
        testCancellationReportsQuiescenceAfterActiveReaderFinishes()
        print("NativeSelectionCaptureCoordinatorTests: \(passed) passed")
    }
}
