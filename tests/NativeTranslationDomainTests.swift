#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN
import Foundation

@main
enum NativeTranslationDomainTests {
    private static var passed = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition() else {
            fatalError("\(message) (\(file):\(line))")
        }
        passed += 1
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var credentialLoads = 0
        private(set) var effectRequests: [NativeTranslationEffectRequest] = []
        private(set) var publications: [(UInt64, NativeTranslationOutcome)] = []

        func loadCredentials(_ expectedFingerprint: String) -> VolcV4Credentials? {
            lock.withLock {
                credentialLoads += 1
                return VolcV4Credentials(
                    accessKey: "AKTEST",
                    secretKey: "SKTEST",
                    fingerprint: expectedFingerprint
                )
            }
        }

        func recordEffect(_ request: NativeTranslationEffectRequest) {
            lock.withLock { effectRequests.append(request) }
        }

        func publish(_ generation: UInt64, _ outcome: NativeTranslationOutcome) {
            lock.withLock { publications.append((generation, outcome)) }
        }

        func snapshot() -> (
            credentialLoads: Int,
            effectRequests: [NativeTranslationEffectRequest],
            publications: [(UInt64, NativeTranslationOutcome)]
        ) {
            lock.withLock { (credentialLoads, effectRequests, publications) }
        }
    }

    private actor ControlledExecutor {
        private var nextIdentifier = 0
        private var continuations: [Int: CheckedContinuation<NativeTranslationEffectResult, Never>] = [:]
        private(set) var requests: [(Int, NativeTranslationEffectRequest)] = []

        func run(_ request: NativeTranslationEffectRequest) async -> NativeTranslationEffectResult {
            let identifier = nextIdentifier
            nextIdentifier += 1
            requests.append((identifier, request))
            return await withCheckedContinuation { continuation in
                continuations[identifier] = continuation
            }
        }

        func count() -> Int { requests.count }

        func resume(_ identifier: Int, with result: NativeTranslationEffectResult) {
            continuations.removeValue(forKey: identifier)?.resume(returning: result)
        }
    }

    private static let installedContext = NativeTranslationRequestContext(
        appleReadiness: .installed,
        volcPrivacy: NativeVolcPrivacyContext(
            hasExplicitConsent: false,
            removalMarker: .unavailable,
            credentialReadiness: .missing,
            verifiedFingerprint: nil
        )
    )

    private static func permittedVolcContext(
        fingerprint: String = "verified-fingerprint"
    ) -> NativeTranslationRequestContext {
        NativeTranslationRequestContext(
            appleReadiness: .unsupported,
            volcPrivacy: NativeVolcPrivacyContext(
                hasExplicitConsent: true,
                removalMarker: .confirmedAbsent,
                credentialReadiness: .active(fingerprint: fingerprint),
                verifiedFingerprint: fingerprint
            )
        )
    }

    private static func ready(_ decision: NativeTranslationInputDecision) -> NativeTranslationInput? {
        guard case let .ready(input) = decision else { return nil }
        return input
    }

    private static func waitUntil(
        _ predicate: @escaping () async -> Bool,
        attempts: Int = 10_000
    ) async {
        for _ in 0..<attempts {
            if await predicate() { return }
            await Task.yield()
        }
        fatalError("timed out waiting for async test condition")
    }

    static func main() async {
        testInputPolicy()
        testPrivacyRouter()
        await testCoordinatorBlockedRoutes()
        await testCoordinatorSuccessAndNoReuse()
        await testCoordinatorGenerationAndInvalidation()
        print("NativeTranslationDomainTests: \(passed) passed")
    }

    private static func testInputPolicy() {
        expect(
            NativeTranslationInputPolicy.prepare(nil) == .failure(.emptyInput),
            "nil maps to empty failure"
        )
        expect(
            NativeTranslationInputPolicy.prepare("\r\n\r \u{2003}") == .failure(.emptyInput),
            "line ending normalization precedes scalar whitespace trim"
        )

        let normalized = ready(NativeTranslationInputPolicy.prepare("\u{2003}ab\r\ncd\rEF\u{00A0}"))
        expect(normalized?.text == "ab\ncd\nEF", "CRLF and CR normalize while internal content remains")
        expect(normalized?.languages == NativeTranslationLanguagePair(), "language pair is fixed en to zh")

        let exact = ready(NativeTranslationInputPolicy.prepare(String(repeating: "a", count: 5_000)))
        expect(exact?.scalarCount == 5_000 && exact?.wasTruncated == false, "5000 scalars do not truncate")
        let onePast = ready(
            NativeTranslationInputPolicy.prepare(String(repeating: "a", count: 4_999) + "😀Z")
        )
        expect(onePast?.scalarCount == 5_000, "limit counts Unicode scalars")
        expect(onePast?.text.hasSuffix("😀") == true, "scalar prefix never splits a non-BMP scalar")
        expect(onePast?.wasTruncated == true, "5001 scalars mark truncation")

        expect(
            ready(NativeTranslationInputPolicy.prepare("ab你好"))?.text == "ab你好",
            "CJK ratio exactly 0.5 remains eligible"
        )
        expect(
            NativeTranslationInputPolicy.prepare("a你好") == .failure(.sourceLanguageMismatch),
            "CJK ratio strictly above 0.5 fails without text"
        )
        expect(
            NativeTranslationInputPolicy.prepare("a、、") == .failure(.sourceLanguageMismatch),
            "CJK punctuation range 3000-303F is included"
        )
        expect(
            NativeTranslationInputPolicy.prepare("aＡＢ") == .failure(.sourceLanguageMismatch),
            "fullwidth range FF00-FFEF is included"
        )
        expect(
            ready(NativeTranslationInputPolicy.prepare("𠀀𠀁"))?.text == "𠀀𠀁",
            "CJK extension scalars outside the frozen ranges do not trip the CJK ratio"
        )
        expect(
            NativeTranslationInputPolicy.prepare("…😀\u{200D}!") == .skipped(.tooShort),
            "punctuation emoji and ZWJ are not alphabetic"
        )
        expect(
            NativeTranslationInputPolicy.prepare("e\u{0301}") == .skipped(.tooShort),
            "combining mark does not turn one alphabetic scalar into two"
        )
        let unnormalized = ready(NativeTranslationInputPolicy.prepare("e\u{0301}x"))
        expect(
            unnormalized?.text.unicodeScalars.map(\.value) == [0x65, 0x301, 0x78],
            "input scalar sequence is not normalized to NFC"
        )
        let secretInput = NativeTranslationInputPolicy.prepare("source-secret-should-not-reflect")
        expect(
            !String(describing: secretInput).contains("source-secret"),
            "input decision description never reflects source text"
        )
        expect(
            !String(reflecting: secretInput).contains("source-secret"),
            "input decision debug reflection never reflects source text"
        )
        expect(
            ready(NativeTranslationInputPolicy.prepare("éx"))?.scalarCount == 2,
            "precomposed alphabetic scalars are counted directly"
        )
        expect(
            NativeTranslationInputPolicy.prepare("A") == .skipped(.tooShort),
            "one alphabetic scalar is skipped"
        )
        expect(
            ready(NativeTranslationInputPolicy.prepare("a1b2"))?.text == "a1b2",
            "two alphabetic scalars are eligible"
        )

        let includedCJKScalars: [UInt32] = [
            0x4E00, 0x9FFF, 0x3001, 0x303F, 0xFF00, 0xFFEF,
        ]
        for value in includedCJKScalars {
            let scalar = UnicodeScalar(value)!
            expect(
                NativeTranslationInputPolicy.cjkRatio(String(scalar)) == 1,
                "frozen CJK endpoint U+\(String(value, radix: 16)) is included"
            )
        }
        let excludedCJKScalars: [UInt32] = [
            0x4DFF, 0xA000, 0x2FFF, 0x3040, 0xFEFF, 0xFFF0,
        ]
        for value in excludedCJKScalars {
            let scalar = UnicodeScalar(value)!
            expect(
                NativeTranslationInputPolicy.cjkRatio(String(scalar)) == 0,
                "neighbor U+\(String(value, radix: 16)) is outside frozen ranges"
            )
        }
        expect(
            NativeTranslationInputPolicy.cjkRatio("\u{3000}") == 0,
            "U+3000 is excluded from the ratio denominator as whitespace"
        )
        expect(
            NativeTranslationInputPolicy.alphabeticScalarCount("\u{2163}") == 1,
            "Unicode Roman numeral is alphabetic by scalar property"
        )
        expect(
            ready(NativeTranslationInputPolicy.prepare("\u{2163}\u{2163}"))?.scalarCount == 2,
            "two alphabetic Roman numeral scalars are eligible"
        )
    }

    private static func testPrivacyRouter() {
        let appleStates: [(NativeAppleTranslationReadiness, NativeTranslationRouteDecision)] = [
            (.installed, .execute(.apple)),
            (.supportedNeedsPreparation, .failure(.appleNeedsPreparation)),
            (.unsupported, .failure(.appleUnsupported)),
        ]
        for (readiness, expected) in appleStates {
            let context = NativeTranslationRequestContext(
                appleReadiness: readiness,
                volcPrivacy: permittedVolcContext().volcPrivacy
            )
            expect(
                NativeTranslationPrivacyRouter.decide(requestedEngine: .apple, context: context)
                    == expected,
                "Apple readiness has no cloud route"
            )
        }

        let fingerprint = "verified-fingerprint"
        let allowed = permittedVolcContext(fingerprint: fingerprint)
        expect(
            NativeTranslationPrivacyRouter.decide(requestedEngine: .volc, context: allowed)
                == .execute(.volc(expectedFingerprint: fingerprint)),
            "Volc requires the complete privacy permit"
        )

        let blocked: [(NativeVolcPrivacyContext, NativeTranslationFailure)] = [
            (
                NativeVolcPrivacyContext(
                    hasExplicitConsent: false,
                    removalMarker: .confirmedAbsent,
                    credentialReadiness: .active(fingerprint: fingerprint),
                    verifiedFingerprint: fingerprint
                ),
                .cloudConsentRequired
            ),
            (
                NativeVolcPrivacyContext(
                    hasExplicitConsent: true,
                    removalMarker: .present,
                    credentialReadiness: .active(fingerprint: fingerprint),
                    verifiedFingerprint: fingerprint
                ),
                .cloudRemovalPresent
            ),
            (
                NativeVolcPrivacyContext(
                    hasExplicitConsent: true,
                    removalMarker: .unavailable,
                    credentialReadiness: .active(fingerprint: fingerprint),
                    verifiedFingerprint: fingerprint
                ),
                .cloudRemovalStateUnavailable
            ),
            (
                NativeVolcPrivacyContext(
                    hasExplicitConsent: true,
                    removalMarker: .confirmedAbsent,
                    credentialReadiness: .missing,
                    verifiedFingerprint: fingerprint
                ),
                .cloudCredentialsMissing
            ),
            (
                NativeVolcPrivacyContext(
                    hasExplicitConsent: true,
                    removalMarker: .confirmedAbsent,
                    credentialReadiness: .pendingOnly,
                    verifiedFingerprint: fingerprint
                ),
                .cloudCredentialsPending
            ),
            (
                NativeVolcPrivacyContext(
                    hasExplicitConsent: true,
                    removalMarker: .confirmedAbsent,
                    credentialReadiness: .active(fingerprint: fingerprint),
                    verifiedFingerprint: nil
                ),
                .cloudCredentialUnverified
            ),
            (
                NativeVolcPrivacyContext(
                    hasExplicitConsent: true,
                    removalMarker: .confirmedAbsent,
                    credentialReadiness: .active(fingerprint: fingerprint),
                    verifiedFingerprint: "different"
                ),
                .cloudCredentialUnverified
            ),
        ]
        for (privacy, failure) in blocked {
            let context = NativeTranslationRequestContext(
                appleReadiness: .installed,
                volcPrivacy: privacy
            )
            expect(
                NativeTranslationPrivacyRouter.decide(requestedEngine: .volc, context: context)
                    == .failure(failure),
                "blocked Volc route fails closed without an Apple route"
            )
        }

        let secret = "AKFAKE123 SKFAKE456"
        let privateContext = NativeVolcPrivacyContext(
            hasExplicitConsent: true,
            removalMarker: .confirmedAbsent,
            credentialReadiness: .active(fingerprint: secret),
            verifiedFingerprint: secret
        )
        expect(!privateContext.description.contains(secret), "privacy context description is redacted")
        let privateRoute = NativeTranslationRouteDecision.execute(
            .volc(expectedFingerprint: secret)
        )
        expect(!String(describing: privateRoute).contains(secret), "route description hides fingerprint")
        expect(!String(reflecting: privateRoute).contains(secret), "route reflection hides fingerprint")
        let privateRequest = NativeTranslationRequestContext(
            appleReadiness: .installed,
            volcPrivacy: privateContext
        )
        expect(!String(describing: privateRequest).contains(secret), "request context description is redacted")
        expect(!String(reflecting: privateRequest).contains(secret), "request context reflection is redacted")
    }

    private static func testCoordinatorBlockedRoutes() async {
        let fingerprint = "f"
        let blockedContexts: [(NativeTranslationEngine, NativeTranslationRequestContext, NativeTranslationOutcome)] = [
            (
                .apple,
                NativeTranslationRequestContext(
                    appleReadiness: .supportedNeedsPreparation,
                    volcPrivacy: permittedVolcContext().volcPrivacy
                ),
                .failure(.appleNeedsPreparation)
            ),
            (
                .apple,
                NativeTranslationRequestContext(
                    appleReadiness: .unsupported,
                    volcPrivacy: permittedVolcContext().volcPrivacy
                ),
                .failure(.appleUnsupported)
            ),
            (
                .volc,
                NativeTranslationRequestContext(
                    appleReadiness: .installed,
                    volcPrivacy: NativeVolcPrivacyContext(
                        hasExplicitConsent: false,
                        removalMarker: .confirmedAbsent,
                        credentialReadiness: .active(fingerprint: fingerprint),
                        verifiedFingerprint: fingerprint
                    )
                ),
                .failure(.cloudConsentRequired)
            ),
            (
                .volc,
                NativeTranslationRequestContext(
                    appleReadiness: .installed,
                    volcPrivacy: NativeVolcPrivacyContext(
                        hasExplicitConsent: true,
                        removalMarker: .present,
                        credentialReadiness: .active(fingerprint: fingerprint),
                        verifiedFingerprint: fingerprint
                    )
                ),
                .failure(.cloudRemovalPresent)
            ),
            (
                .volc,
                NativeTranslationRequestContext(
                    appleReadiness: .installed,
                    volcPrivacy: NativeVolcPrivacyContext(
                        hasExplicitConsent: true,
                        removalMarker: .unavailable,
                        credentialReadiness: .active(fingerprint: fingerprint),
                        verifiedFingerprint: fingerprint
                    )
                ),
                .failure(.cloudRemovalStateUnavailable)
            ),
            (
                .volc,
                NativeTranslationRequestContext(
                    appleReadiness: .installed,
                    volcPrivacy: NativeVolcPrivacyContext(
                        hasExplicitConsent: true,
                        removalMarker: .confirmedAbsent,
                        credentialReadiness: .missing,
                        verifiedFingerprint: fingerprint
                    )
                ),
                .failure(.cloudCredentialsMissing)
            ),
            (
                .volc,
                NativeTranslationRequestContext(
                    appleReadiness: .installed,
                    volcPrivacy: NativeVolcPrivacyContext(
                        hasExplicitConsent: true,
                        removalMarker: .confirmedAbsent,
                        credentialReadiness: .pendingOnly,
                        verifiedFingerprint: "f"
                    )
                ),
                .failure(.cloudCredentialsPending)
            ),
            (
                .volc,
                NativeTranslationRequestContext(
                    appleReadiness: .installed,
                    volcPrivacy: NativeVolcPrivacyContext(
                        hasExplicitConsent: true,
                        removalMarker: .confirmedAbsent,
                        credentialReadiness: .active(fingerprint: fingerprint),
                        verifiedFingerprint: nil
                    )
                ),
                .failure(.cloudCredentialUnverified)
            ),
            (
                .volc,
                NativeTranslationRequestContext(
                    appleReadiness: .installed,
                    volcPrivacy: NativeVolcPrivacyContext(
                        hasExplicitConsent: true,
                        removalMarker: .confirmedAbsent,
                        credentialReadiness: .active(fingerprint: fingerprint),
                        verifiedFingerprint: "different"
                    )
                ),
                .failure(.cloudCredentialUnverified)
            ),
        ]

        for (engine, context, expected) in blockedContexts {
            let recorder = Recorder()
            let coordinator = NativeTranslationDomainCoordinator(
                credentialLoader: { recorder.loadCredentials($0) },
                executor: NativeTranslationFakeExecutor { request in
                    recorder.recordEffect(request)
                    return .success(text: "should not run")
                },
                publisher: { recorder.publish($0, $1) }
            )
            _ = await coordinator.begin(
                sourceText: "hello",
                requestedEngine: engine,
                context: context
            )
            await waitUntil { recorder.snapshot().publications.count == 1 }
            let snapshot = recorder.snapshot()
            expect(snapshot.credentialLoads == 0, "blocked route does not load credentials")
            expect(snapshot.effectRequests.isEmpty, "blocked route does not execute either engine")
            expect(snapshot.publications.first?.1 == expected, "blocked route publishes typed failure")
            let hasRetainedInput = await coordinator.hasRetainedInput()
            expect(hasRetainedInput == false, "terminal failure releases input")
        }

        let early = Recorder()
        let coordinator = NativeTranslationDomainCoordinator(
            credentialLoader: { early.loadCredentials($0) },
            executor: NativeTranslationFakeExecutor { request in
                early.recordEffect(request)
                return .success(text: "should not run")
            },
            publisher: { early.publish($0, $1) }
        )
        _ = await coordinator.begin(
            sourceText: "!",
            requestedEngine: .volc,
            context: permittedVolcContext()
        )
        await waitUntil { early.snapshot().publications.count == 1 }
        expect(early.snapshot().publications.first?.1 == .skipped(.tooShort), "too-short publishes reason only")
        expect(early.snapshot().credentialLoads == 0, "input early return happens before credential load")
        expect(early.snapshot().effectRequests.isEmpty, "input early return has zero effects")
    }

    private static func testCoordinatorSuccessAndNoReuse() async {
        let recorder = Recorder()
        let coordinator = NativeTranslationDomainCoordinator(
            credentialLoader: { recorder.loadCredentials($0) },
            executor: NativeTranslationFakeExecutor { request in
                recorder.recordEffect(request)
                return .success(text: request.engine == .apple ? "苹果译文" : "火山译文")
            },
            publisher: { recorder.publish($0, $1) }
        )

        _ = await coordinator.begin(
            sourceText: "hello",
            requestedEngine: .apple,
            context: installedContext
        )
        await waitUntil { recorder.snapshot().publications.count == 1 }
        _ = await coordinator.begin(
            sourceText: "hello",
            requestedEngine: .apple,
            context: installedContext
        )
        await waitUntil { recorder.snapshot().publications.count == 2 }
        var snapshot = recorder.snapshot()
        expect(snapshot.effectRequests.count == 2, "identical inputs execute twice")
        expect(snapshot.credentialLoads == 0, "Apple request never loads Volc credentials")
        expect(
            snapshot.publications.last?.1
                == .success(
                    NativeTranslationSuccess(
                        engine: .apple,
                        text: "苹果译文",
                        inputWasTruncated: false
                    )
                ),
            "Apple success contains one matching engine"
        )

        _ = await coordinator.begin(
            sourceText: "hello",
            requestedEngine: .volc,
            context: permittedVolcContext()
        )
        await waitUntil { recorder.snapshot().publications.count == 3 }
        _ = await coordinator.begin(
            sourceText: "hello",
            requestedEngine: .volc,
            context: permittedVolcContext()
        )
        await waitUntil { recorder.snapshot().publications.count == 4 }
        snapshot = recorder.snapshot()
        expect(snapshot.credentialLoads == 2, "each permitted Volc request loads a verified snapshot")
        expect(snapshot.effectRequests.filter { $0.engine == .volc }.count == 2, "identical Volc input executes twice")
        expect(snapshot.effectRequests.last?.engine == .volc, "permitted Volc executes only Volc")
        expect(
            snapshot.effectRequests.last?.volcCredentials?.fingerprint == "verified-fingerprint",
            "executor receives the verified active credential snapshot"
        )
        expect(
            snapshot.publications.last?.1
                == .success(
                    NativeTranslationSuccess(
                        engine: .volc,
                        text: "火山译文",
                        inputWasTruncated: false
                    )
                ),
            "Volc success contains one matching engine"
        )
        let hasRetainedSuccessInput = await coordinator.hasRetainedInput()
        expect(hasRetainedSuccessInput == false, "terminal success releases source input")

        let mismatch = Recorder()
        let mismatchedCoordinator = NativeTranslationDomainCoordinator(
            credentialLoader: { _ in
                VolcV4Credentials(accessKey: "AK", secretKey: "SK", fingerprint: "changed")
            },
            executor: NativeTranslationFakeExecutor { request in
                mismatch.recordEffect(request)
                return .success(text: "should not run")
            },
            publisher: { mismatch.publish($0, $1) }
        )
        _ = await mismatchedCoordinator.begin(
            sourceText: "hello",
            requestedEngine: .volc,
            context: permittedVolcContext()
        )
        await waitUntil { mismatch.snapshot().publications.count == 1 }
        expect(mismatch.snapshot().effectRequests.isEmpty, "changed credential snapshot never executes")
        expect(
            mismatch.snapshot().publications.first?.1 == .failure(.cloudCredentialSnapshotMismatch),
            "changed snapshot fails with no fallback"
        )

        let emptySnapshot = Recorder()
        let emptySnapshotCoordinator = NativeTranslationDomainCoordinator(
            credentialLoader: { _ in
                VolcV4Credentials(accessKey: "", secretKey: "", fingerprint: "verified-fingerprint")
            },
            executor: NativeTranslationFakeExecutor { request in
                emptySnapshot.recordEffect(request)
                return .success(text: "should not run")
            },
            publisher: { emptySnapshot.publish($0, $1) }
        )
        _ = await emptySnapshotCoordinator.begin(
            sourceText: "hello",
            requestedEngine: .volc,
            context: permittedVolcContext()
        )
        await waitUntil { emptySnapshot.snapshot().publications.count == 1 }
        expect(emptySnapshot.snapshot().effectRequests.isEmpty, "empty credential snapshot has zero effects")
        expect(
            emptySnapshot.snapshot().publications.first?.1
                == .failure(.cloudCredentialSnapshotMismatch),
            "empty credential snapshot fails closed"
        )

        let appleFailure = Recorder()
        let appleFailureCoordinator = NativeTranslationDomainCoordinator(
            credentialLoader: { appleFailure.loadCredentials($0) },
            executor: NativeTranslationFakeExecutor { request in
                appleFailure.recordEffect(request)
                return .failure(.appleExecutionFailed)
            },
            publisher: { appleFailure.publish($0, $1) }
        )
        _ = await appleFailureCoordinator.begin(
            sourceText: "hello",
            requestedEngine: .apple,
            context: installedContext
        )
        await waitUntil { appleFailure.snapshot().publications.count == 1 }
        expect(
            appleFailure.snapshot().effectRequests.map(\.engine) == [.apple],
            "Apple execution failure never dispatches Volc"
        )
        expect(appleFailure.snapshot().credentialLoads == 0, "Apple failure never reads cloud credentials")

        for failure in [NativeTranslationFailure.volcCredential, .volcService, .volcMalformedResponse] {
            let volcFailure = Recorder()
            let volcFailureCoordinator = NativeTranslationDomainCoordinator(
                credentialLoader: { volcFailure.loadCredentials($0) },
                executor: NativeTranslationFakeExecutor { request in
                    volcFailure.recordEffect(request)
                    return .failure(failure)
                },
                publisher: { volcFailure.publish($0, $1) }
            )
            _ = await volcFailureCoordinator.begin(
                sourceText: "hello",
                requestedEngine: .volc,
                context: permittedVolcContext()
            )
            await waitUntil { volcFailure.snapshot().publications.count == 1 }
            expect(
                volcFailure.snapshot().effectRequests.map(\.engine) == [.volc],
                "Volc failure \(failure) never dispatches Apple"
            )
            expect(
                volcFailure.snapshot().publications.first?.1 == .failure(failure),
                "Volc failure remains typed and engine-local"
            )
        }
    }

    private static func testCoordinatorGenerationAndInvalidation() async {
        let controlled = ControlledExecutor()
        let recorder = Recorder()
        let coordinator = NativeTranslationDomainCoordinator(
            credentialLoader: { recorder.loadCredentials($0) },
            executor: NativeTranslationFakeExecutor { request in
                await controlled.run(request)
            },
            publisher: { recorder.publish($0, $1) }
        )

        let first = await coordinator.begin(
            sourceText: "first request",
            requestedEngine: .apple,
            context: installedContext
        )
        await waitUntil { await controlled.count() == 1 }
        let hasActiveInput = await coordinator.hasRetainedInput()
        expect(hasActiveInput, "active effect temporarily retains processed input")

        let second = await coordinator.begin(
            sourceText: "second request",
            requestedEngine: .apple,
            context: installedContext
        )
        await waitUntil { await controlled.count() == 2 }
        expect(second > first, "new request advances generation")

        await controlled.resume(0, with: .success(text: "stale secret result"))
        await Task.yield()
        expect(recorder.snapshot().publications.isEmpty, "late old success has zero publish")
        await controlled.resume(1, with: .success(text: "current result"))
        await waitUntil { recorder.snapshot().publications.count == 1 }
        expect(recorder.snapshot().publications.first?.0 == second, "only current generation publishes")
        expect(
            recorder.snapshot().publications.first?.1
                == .success(
                    NativeTranslationSuccess(
                        engine: .apple,
                        text: "current result",
                        inputWasTruncated: false
                    )
                ),
            "late result cannot overwrite current result"
        )
        let hasPublishedInput = await coordinator.hasRetainedInput()
        expect(hasPublishedInput == false, "publish gate releases processed input")

        let invalidationReasons: [NativeTranslationInvalidationReason] = [
            .pause,
            .stop,
            .accessibilityRevoked,
            .engineChanged,
            .credentialsChanged,
            .removalStateChanged,
            .ownerChanged,
        ]
        for reason in invalidationReasons {
            let delayed = ControlledExecutor()
            let sink = Recorder()
            let instance = NativeTranslationDomainCoordinator(
                credentialLoader: { sink.loadCredentials($0) },
                executor: NativeTranslationFakeExecutor { request in await delayed.run(request) },
                publisher: { sink.publish($0, $1) }
            )
            _ = await instance.begin(
                sourceText: "cancel me",
                requestedEngine: .apple,
                context: installedContext
            )
            await waitUntil { await delayed.count() == 1 }
            let before = await instance.currentGeneration()
            await instance.invalidate(reason)
            let after = await instance.currentGeneration()
            expect(after > before, "\(reason) advances generation")
            let hasInvalidatedInput = await instance.hasRetainedInput()
            expect(hasInvalidatedInput == false, "\(reason) releases input")
            await delayed.resume(0, with: .failure(.appleExecutionFailed))
            await Task.yield()
            expect(sink.snapshot().publications.isEmpty, "\(reason) blocks late failure publish")
        }

        let cancelledRecorder = Recorder()
        let cancelledCoordinator = NativeTranslationDomainCoordinator(
            credentialLoader: { cancelledRecorder.loadCredentials($0) },
            executor: NativeTranslationFakeExecutor { _ in .cancelled },
            publisher: { cancelledRecorder.publish($0, $1) }
        )
        _ = await cancelledCoordinator.begin(
            sourceText: "cancelled effect",
            requestedEngine: .apple,
            context: installedContext
        )
        await waitUntil { cancelledRecorder.snapshot().publications.count == 1 }
        expect(
            cancelledRecorder.snapshot().publications.first?.1 == .cancelled,
            "current cancellation is not classified as an error"
        )
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
#endif
