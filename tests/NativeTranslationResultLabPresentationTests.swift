import Foundation

@main
enum NativeTranslationResultLabPresentationTests {
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
    private static func withLease(
        _ body: (NativeTranslationOverlayExternalPresentationLease) -> Void
    ) {
        let registry = NativeTranslationOverlayExternalPresentationRegistry()
        let lease = registry.begin(sessionGeneration: 7) { _ in }
        body(lease)
    }

    private static func envelope(
        fixture: NativeTranslationResultLabFixtureID,
        engine: NativeTranslationEngine,
        generation: UInt64 = 41,
        lease: NativeTranslationOverlayExternalPresentationLease,
        outcome: NativeTranslationOutcome,
        elapsed: Int = 218,
        truncated: Bool = false
    ) -> NativeTranslationResultLabEnvelope {
        NativeTranslationResultLabEnvelope(
            fixtureID: fixture,
            provenance: .simulated,
            requestedEngine: engine,
            domainGeneration: generation,
            presentationLease: lease,
            outcome: outcome,
            simulatedElapsedMilliseconds: elapsed,
            inputWasTruncated: truncated
        )
    }

    private static func map(
        _ envelope: NativeTranslationResultLabEnvelope,
        expectedGeneration: UInt64 = 41,
        expectedLease: NativeTranslationOverlayExternalPresentationLease
    ) -> NativeTranslationResultLabPresentationDecision {
        NativeTranslationResultLabPresentationBridge.map(
            envelope,
            expectedDomainGeneration: expectedGeneration,
            expectedLease: expectedLease
        )
    }

    @MainActor
    private static func testFixedSuccessMatrix() {
        withLease { lease in
            let cases: [(
                NativeTranslationResultLabFixtureID,
                NativeTranslationEngine,
                String,
                String
            )] = [
                (.appleFixedSample, .apple, NativeTranslationResultLabFixtures.appleResult, "Apple 模拟译文"),
                (.volcFixedSample, .volc, NativeTranslationResultLabFixtures.volcResult, "火山模拟译文"),
            ]
            for (fixture, engine, result, title) in cases {
                let decision = map(
                    envelope(
                        fixture: fixture,
                        engine: engine,
                        lease: lease,
                        outcome: .success(
                            NativeTranslationSuccess(
                                engine: engine,
                                text: result,
                                inputWasTruncated: false
                            )
                        )
                    ),
                    expectedLease: lease
                )
                guard case let .present(presentation) = decision else {
                    expect(false, "fixed result presents")
                    continue
                }
                expect(presentation.overlayState.kind == .success, "fixed result is success")
                expect(presentation.overlayState.title == title, "engine label is simulated")
                expect(presentation.overlayState.copyText == result, "copy is exact fixed result")
                expect(presentation.overlayState.body == result, "visible body is exact fixed result")
                expect(presentation.overlayState.metadata?.contains("模拟耗时") == true, "elapsed is labelled simulated")
                expect(presentation.overlayState.fallbackNotice == nil, "Result Lab has no engine substitution notice")
            }
        }
    }

    @MainActor
    private static func testStrictLeaseAndGenerationGate() {
        let registry = NativeTranslationOverlayExternalPresentationRegistry()
        let current = registry.begin(sessionGeneration: 1) { _ in }
        let stale = registry.begin(sessionGeneration: 2) { _ in }
        let valid = envelope(
            fixture: .appleFixedSample,
            engine: .apple,
            lease: stale,
            outcome: .success(
                NativeTranslationSuccess(
                    engine: .apple,
                    text: NativeTranslationResultLabFixtures.appleResult,
                    inputWasTruncated: false
                )
            )
        )
        expect(
            map(valid, expectedGeneration: 42, expectedLease: stale) == .drop,
            "stale provider generation is silently dropped"
        )
        expect(
            map(valid, expectedLease: current) == .drop,
            "stale presentation lease is silently dropped"
        )
    }

    @MainActor
    private static func testMaliciousSuccessFailsClosed() {
        withLease { lease in
            let badResults = [
                "任意非固定译文",
                NativeTranslationResultLabFixtures.appleResult + "\u{0000}",
                NativeTranslationResultLabFixtures.appleResult + "\u{007F}",
                String(repeating: "a", count: 20_001),
                "   \n\t",
            ]
            for result in badResults {
                let decision = map(
                    envelope(
                        fixture: .appleFixedSample,
                        engine: .apple,
                        lease: lease,
                        outcome: .success(
                            NativeTranslationSuccess(
                                engine: .apple,
                                text: result,
                                inputWasTruncated: false
                            )
                        )
                    ),
                    expectedLease: lease
                )
                guard case let .present(presentation) = decision else {
                    expect(false, "bad success maps to visible safety state")
                    continue
                }
                expect(presentation.overlayState.title == "结果未通过 Debug 安全检查", "bad result is safety failure")
                expect(presentation.overlayState.copyText == nil, "bad result is never copyable")
                expect(!presentation.overlayState.body.contains(result), "bad result is not echoed")
                expect(presentation.overlayState.body.contains("未调用 Apple Translation"), "Apple safety state preserves the no-live boundary")
                expect(presentation.overlayState.metadata?.contains("Apple 离线（模拟）") == true, "Apple safety metadata names the requested engine")
            }

            for (envelopeFlag, successFlag) in [(true, true), (true, false), (false, true)] {
                let decision = map(
                    envelope(
                        fixture: .appleFixedSample,
                        engine: .apple,
                        lease: lease,
                        outcome: .success(
                            NativeTranslationSuccess(
                                engine: .apple,
                                text: NativeTranslationResultLabFixtures.appleResult,
                                inputWasTruncated: successFlag
                            )
                        ),
                        truncated: envelopeFlag
                    ),
                    expectedLease: lease
                )
                guard case let .present(presentation) = decision else {
                    expect(false, "unexpected truncation produces safety state")
                    continue
                }
                expect(presentation.overlayState.copyText == nil, "fixed short fixture cannot claim truncation")
            }

            let engineMismatch = map(
                envelope(
                    fixture: .appleFixedSample,
                    engine: .apple,
                    lease: lease,
                    outcome: .success(
                        NativeTranslationSuccess(
                            engine: .volc,
                            text: NativeTranslationResultLabFixtures.volcResult,
                            inputWasTruncated: false
                        )
                    )
                ),
                expectedLease: lease
            )
            guard case let .present(mismatch) = engineMismatch else {
                expect(false, "engine mismatch fails closed")
                return
            }
            expect(mismatch.overlayState.title == "结果未通过 Debug 安全检查", "engine mismatch is safety failure")
            expect(mismatch.overlayState.copyText == nil, "engine mismatch drops result")

            let volcInvalid = map(
                envelope(
                    fixture: .volcFixedSample,
                    engine: .volc,
                    lease: lease,
                    outcome: .success(
                        NativeTranslationSuccess(
                            engine: .volc,
                            text: "非固定译文",
                            inputWasTruncated: false
                        )
                    )
                ),
                expectedLease: lease
            )
            guard case let .present(volcSafety) = volcInvalid else {
                expect(false, "invalid Volc result fails closed")
                return
            }
            expect(volcSafety.overlayState.body.contains("未读密钥、未联网、不计费"), "Volc safety state preserves every no-live boundary")
            expect(volcSafety.overlayState.metadata?.contains("火山云端（模拟）") == true, "Volc safety metadata names the requested engine")
        }
    }

    @MainActor
    private static func testOutcomeAndFailureMatrix() {
        withLease { lease in
            for outcome in [
                NativeTranslationOutcome.skipped(.tooShort),
                .failure(.emptyInput),
                .failure(.sourceLanguageMismatch),
            ] {
                let decision = map(
                    envelope(
                        fixture: .appleFixedSample,
                        engine: .apple,
                        lease: lease,
                        outcome: outcome
                    ),
                    expectedLease: lease
                )
                guard case let .present(presentation) = decision else {
                    expect(false, "invalid fixed input is safety failure")
                    continue
                }
                expect(presentation.overlayState.title == "结果未通过 Debug 安全检查", "fixed input contract is strict")
            }
            expect(
                map(
                    envelope(
                        fixture: .appleFixedSample,
                        engine: .apple,
                        lease: lease,
                        outcome: .cancelled
                    ),
                    expectedLease: lease
                ) == .dismiss,
                "cancelled is silent"
            )

            let appleFailures: [NativeTranslationFailure] = [
                .appleNeedsPreparation, .appleUnsupported,
                .appleTemporarilyUnavailable, .appleExecutionFailed,
            ]
            for failure in appleFailures {
                let decision = map(
                    envelope(
                        fixture: .appleFixedSample,
                        engine: .apple,
                        lease: lease,
                        outcome: .failure(failure)
                    ),
                    expectedLease: lease
                )
                guard case let .present(presentation) = decision else {
                    expect(false, "Apple typed failure is represented")
                    continue
                }
                expect(presentation.overlayState.kind == .notice || presentation.overlayState.kind == .error, "Apple failure is terminal")
                expect(presentation.overlayState.copyText == nil, "Apple error cannot copy")
                expect(presentation.overlayState.cta == nil, "Apple error has no production CTA")
            }

            let volcFailures: [NativeTranslationFailure] = [
                .cloudConsentRequired, .cloudRemovalPresent,
                .cloudRemovalStateUnavailable, .cloudCredentialsMissing,
                .cloudCredentialsPending, .cloudCredentialUnverified,
                .cloudCredentialSnapshotMismatch, .volcCredential, .volcNetwork,
                .volcTransportSecurity, .volcTimeout, .volcQuota, .volcService,
                .volcHTTP, .volcMalformedResponse,
            ]
            for failure in volcFailures {
                let decision = map(
                    envelope(
                        fixture: .volcFixedSample,
                        engine: .volc,
                        lease: lease,
                        outcome: .failure(failure),
                        elapsed: 386
                    ),
                    expectedLease: lease
                )
                guard case let .present(presentation) = decision else {
                    expect(false, "Volc typed failure is represented")
                    continue
                }
                expect(presentation.overlayState.copyText == nil, "Volc error cannot copy")
                expect(presentation.overlayState.cta == nil, "Volc error has no production CTA")
            }

            let crossEngine = map(
                envelope(
                    fixture: .appleFixedSample,
                    engine: .apple,
                    lease: lease,
                    outcome: .failure(.volcNetwork)
                ),
                expectedLease: lease
            )
            guard case let .present(crossEngineState) = crossEngine else {
                expect(false, "cross-engine error fails closed")
                return
            }
            expect(crossEngineState.overlayState.title == "结果未通过 Debug 安全检查", "cross-engine error is safety failure")
        }
    }

    @MainActor
    static func main() {
        testFixedSuccessMatrix()
        testStrictLeaseAndGenerationGate()
        testMaliciousSuccessFailsClosed()
        testOutcomeAndFailureMatrix()
        print("NativeTranslationResultLabPresentationTests: \(passed) passed")
    }
}
