import Foundation

@main
enum NativeTranslationOverlayExternalPresentationTests {
    private static var passed = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL: \(message)\n").utf8))
            exit(1)
        }
        passed += 1
    }

    @MainActor
    private static func testOpaqueLeaseAndSingleTerminal() {
        let registry = NativeTranslationOverlayExternalPresentationRegistry()
        var dismissals: [NativeTranslationOverlayDismissReason] = []
        let lease = registry.begin(sessionGeneration: 11) { dismissals.append($0) }

        expect(registry.isCurrent(lease, sessionGeneration: 11), "matching lease is current")
        expect(!registry.isCurrent(lease, sessionGeneration: 12), "session generation is distinct")
        expect(registry.acceptTerminal(lease, sessionGeneration: 11), "first terminal is accepted")
        expect(!registry.acceptTerminal(lease, sessionGeneration: 11), "duplicate terminal is rejected")
        expect(registry.invalidate(lease, reason: .close), "current lease invalidates")
        expect(!registry.invalidate(lease, reason: .escape), "repeat invalidation is idempotent")
        expect(dismissals == [.close], "dismiss callback fires exactly once")
        expect(!lease.description.contains("11"), "lease description redacts generations")
    }

    @MainActor
    private static func testReplacementAndReentrantDismissal() {
        let registry = NativeTranslationOverlayExternalPresentationRegistry()
        var dismissals: [String] = []
        var secondLease: NativeTranslationOverlayExternalPresentationLease?
        let first = registry.begin(sessionGeneration: 1) { reason in
            dismissals.append("first:\(reason)")
            secondLease = registry.begin(sessionGeneration: 2) {
                dismissals.append("second:\($0)")
            }
        }

        expect(registry.invalidate(first, reason: .outside), "first lease invalidates")
        guard let secondLease else {
            expect(false, "dismiss callback may synchronously begin replacement")
            return
        }
        expect(registry.isCurrent(secondLease, sessionGeneration: 2), "reentrant replacement survives")
        expect(!registry.acceptTerminal(first, sessionGeneration: 1), "old lease cannot resolve")
        expect(registry.acceptTerminal(secondLease, sessionGeneration: 2), "replacement resolves")
        registry.invalidateActive(reason: .sleep)
        expect(
            dismissals == ["first:outside", "second:sleep"],
            "replacement and lifecycle callbacks are exact"
        )
    }

    @MainActor
    private static func testBeginRevokesPreviousBeforeMintingNext() {
        let registry = NativeTranslationOverlayExternalPresentationRegistry()
        var callbackSawReplacement = false
        let old = registry.begin(sessionGeneration: 4) { _ in
            callbackSawReplacement = registry.hasActiveLease
        }
        let new = registry.begin(sessionGeneration: 5) { _ in }

        expect(callbackSawReplacement, "replacement is installed before old callback")
        expect(!registry.isCurrent(old, sessionGeneration: 4), "replacement revokes old lease")
        expect(registry.isCurrent(new, sessionGeneration: 5), "replacement is current")
    }

    @MainActor
    private static func testReentrantBeginDuringReplacementCannotOrphanOwner() {
        let registry = NativeTranslationOverlayExternalPresentationRegistry()
        var callbacks: [String] = []
        var reentrant: NativeTranslationOverlayExternalPresentationLease?
        _ = registry.begin(sessionGeneration: 1) { _ in
            callbacks.append("A")
            reentrant = registry.begin(sessionGeneration: 3) { _ in
                callbacks.append("C")
            }
        }
        let outer = registry.begin(sessionGeneration: 2) { _ in
            callbacks.append("B")
        }

        expect(callbacks == ["A", "B"], "outer replacement is explicitly revoked")
        if let reentrant {
            expect(registry.isCurrent(reentrant, sessionGeneration: 3), "reentrant lease remains newest")
        } else {
            expect(false, "reentrant begin ran")
        }
        expect(!registry.isCurrent(outer, sessionGeneration: 2), "outer lease is stale after reentry")
        registry.invalidateActive(reason: .close)
        expect(callbacks == ["A", "B", "C"], "all owners receive exactly one callback")
    }

    private static func testResultLabOwnerSurfaceMousePolicy() {
        expect(
            NativeTranslationResultLabOwnerSurfacePolicy
                .suppressesDismiss(
                    from: .local,
                    eventIsKeyDown: false,
                    panelIsKey: false
                ),
            "the Lab sheet and App menu remain reachable before local actions run"
        )
        expect(
            !NativeTranslationResultLabOwnerSurfacePolicy
                .suppressesDismiss(
                    from: .global,
                    eventIsKeyDown: false,
                    panelIsKey: false
                ),
            "another application's outside click still dismisses"
        )
        expect(
            NativeTranslationResultLabOwnerSurfacePolicy
                .suppressesDismiss(
                    from: .local,
                    eventIsKeyDown: true,
                    panelIsKey: false
                ),
            "passive panel leaves Escape to the Result Lab sheet"
        )
        expect(
            !NativeTranslationResultLabOwnerSurfacePolicy
                .suppressesDismiss(
                    from: .local,
                    eventIsKeyDown: true,
                    panelIsKey: true
                ),
            "explicitly focused panel owns its Escape dismissal"
        )
    }

    @MainActor
    private static func testControllerSessionFirstReplacementIsReentrantSafe() {
        let registry = NativeTranslationOverlayExternalPresentationRegistry()
        var sessionGeneration = 0
        var callbacks: [String] = []
        var reentrantLease: NativeTranslationOverlayExternalPresentationLease?

        func beginLikeController(
            owner: String,
            onDismiss: @escaping (NativeTranslationOverlayDismissReason) -> Void
        ) -> NativeTranslationOverlayExternalPresentationLease? {
            sessionGeneration += 1
            let generation = sessionGeneration
            let lease = registry.begin(
                sessionGeneration: generation,
                onDismiss: onDismiss
            )
            guard sessionGeneration == generation,
                  registry.isCurrent(
                lease,
                sessionGeneration: generation
            ) else { return nil }
            _ = owner
            return lease
        }

        _ = beginLikeController(owner: "A") { _ in
            callbacks.append("A")
            reentrantLease = beginLikeController(owner: "C") { _ in
                callbacks.append("C")
            }
        }
        let outerLease = beginLikeController(owner: "B") { _ in
            callbacks.append("B")
        }

        expect(outerLease == nil, "outer B detects that reentrant C superseded it")
        guard let reentrantLease else {
            expect(false, "A callback may synchronously install C")
            return
        }
        expect(
            registry.isCurrent(
                reentrantLease,
                sessionGeneration: sessionGeneration
            ),
            "controller ordering leaves reentrant C current"
        )
        expect(callbacks == ["A", "B"], "A and superseded B receive one callback")
        registry.invalidateActive(reason: .close)
        expect(callbacks == ["A", "B", "C"], "C receives its one final callback")
    }

    @MainActor
    private static func testLegacyReplacementCannotInvalidateReentrantExternalLease() {
        let registry = NativeTranslationOverlayExternalPresentationRegistry()
        var callbacks: [String] = []
        var reentrant: NativeTranslationOverlayExternalPresentationLease?
        let original = registry.begin(sessionGeneration: 10) { _ in
            callbacks.append("A")
            reentrant = registry.begin(sessionGeneration: 12) { _ in
                callbacks.append("C")
            }
        }
        let capturedOriginal = registry.currentLease
        expect(capturedOriginal == original, "legacy replacement captures exact A lease")

        // Model the legacy session's synchronous placement failure: it
        // dismisses A, whose callback immediately starts external C.
        expect(
            registry.invalidate(original, reason: .displayRemoved),
            "placement failure dismisses original A"
        )
        expect(
            !registry.invalidate(capturedOriginal!, reason: .stop),
            "legacy completion cannot invalidate a lease it did not capture"
        )
        guard let reentrant else {
            expect(false, "A callback creates C")
            return
        }
        expect(registry.isCurrent(reentrant, sessionGeneration: 12), "C survives")
        expect(callbacks == ["A"], "only A has been dismissed")
        registry.invalidateActive(reason: .close)
        expect(callbacks == ["A", "C"], "C receives one later dismissal")
    }

    @MainActor
    static func main() {
        testOpaqueLeaseAndSingleTerminal()
        testReplacementAndReentrantDismissal()
        testBeginRevokesPreviousBeforeMintingNext()
        testReentrantBeginDuringReplacementCannotOrphanOwner()
        testResultLabOwnerSurfaceMousePolicy()
        testControllerSessionFirstReplacementIsReentrantSafe()
        testLegacyReplacementCannotInvalidateReentrantExternalLease()
        print("NativeTranslationOverlayExternalPresentationTests: \(passed) passed")
    }
}
