#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
import Foundation

@main
enum NativeTranslationAppleResultLabBindingPresentationTests {
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
    private static func withCapabilities(
        _ body: (
            NativeTranslationOverlayExternalPresentationLease,
            NativeTranslationAppleResultLabHostReceipt
        ) -> Void
    ) {
        let registry = NativeTranslationOverlayExternalPresentationRegistry()
        let lease = registry.begin(sessionGeneration: 7) { _ in }
        let receiptRegistry = NativeTranslationAppleResultLabHostReceiptRegistry()
        guard let receipt = receiptRegistry.claim(
            runID: 17,
            claimGeneration: 23
        ) else {
            expect(false, "first host claim mints a receipt")
            return
        }
        body(lease, receipt)
    }

    private static func envelope(
        fixture: NativeTranslationAppleResultLabFixtureID = .appleFixedSample,
        provenance: NativeTranslationAppleResultLabProvenance =
            .realAppleTranslation,
        requestedEngine: NativeTranslationEngine = .apple,
        generation: UInt64 = 41,
        lease: NativeTranslationOverlayExternalPresentationLease,
        receipt: NativeTranslationAppleResultLabHostReceipt,
        outcome: NativeTranslationOutcome,
        elapsed: Int = 218,
        truncated: Bool = false
    ) -> NativeTranslationAppleResultLabEnvelope {
        NativeTranslationAppleResultLabEnvelope(
            fixtureID: fixture,
            provenance: provenance,
            requestedEngine: requestedEngine,
            domainGeneration: generation,
            presentationLease: lease,
            hostReceipt: receipt,
            outcome: outcome,
            elapsedMilliseconds: elapsed,
            inputWasTruncated: truncated
        )
    }

    private static func map(
        _ envelope: NativeTranslationAppleResultLabEnvelope,
        expectedGeneration: UInt64 = 41,
        expectedLease: NativeTranslationOverlayExternalPresentationLease,
        expectedReceipt: NativeTranslationAppleResultLabHostReceipt
    ) -> NativeTranslationAppleResultLabPresentationDecision {
        NativeTranslationAppleResultLabPresentationBridge.map(
            envelope,
            expectedDomainGeneration: expectedGeneration,
            expectedLease: expectedLease,
            expectedHostReceipt: expectedReceipt
        )
    }

    private static func success(_ text: String) -> NativeTranslationOutcome {
        .success(
            NativeTranslationSuccess(
                engine: .apple,
                text: text,
                inputWasTruncated: false
            )
        )
    }

    private static func presented(
        _ decision: NativeTranslationAppleResultLabPresentationDecision,
        _ message: String
    ) -> NativeTranslationAppleResultLabValidatedPresentation? {
        guard case let .present(value) = decision else {
            expect(false, message)
            return nil
        }
        return value
    }

    private static func isSafety(
        _ decision: NativeTranslationAppleResultLabPresentationDecision
    ) -> Bool {
        guard case let .present(value) = decision else { return false }
        return value.category == .safetyFailure
            && value.overlayState.title
                == "真实 Apple 结果未通过 Debug 安全检查"
            && value.overlayState.copyText == nil
            && value.overlayState.cta == nil
    }

    private static func testExactStaticPresentations() {
        let loading = NativeTranslationAppleResultLabValidatedPresentation
            .loading(isExtended: false)
        expect(
            loading.overlayState.title == "正在运行真实 Apple Translation…",
            "loading title is exact"
        )
        expect(loading.overlayState.body.isEmpty, "initial loading has no slow hint")
        expect(loading.overlayState.copyText == nil, "loading is not copyable")
        expect(
            loading.overlayState.terminalAnnouncement == nil,
            "loading does not announce a terminal"
        )

        let extended = NativeTranslationAppleResultLabValidatedPresentation
            .loading(isExtended: true)
        expect(
            extended.overlayState.body
                == "仍在等待 Apple Translation；不会改用火山云端。",
            "extended loading text is exact"
        )

        let timeout = NativeTranslationAppleResultLabValidatedPresentation.timeout()
        expect(
            timeout.overlayState.title == "Apple Translation 暂时没有响应",
            "timeout title is exact"
        )
        expect(timeout.category == .timeout, "timeout category is typed")
        expect(timeout.overlayState.copyText == nil, "timeout is not copyable")
        expect(timeout.overlayState.cta == nil, "timeout has no production CTA")

        let safety = NativeTranslationAppleResultLabValidatedPresentation
            .safetyFailure()
        expect(
            safety.overlayState.title
                == "真实 Apple 结果未通过 Debug 安全检查",
            "safety title is exact"
        )
        expect(safety.overlayState.copyText == nil, "safety state is not copyable")
        expect(
            !safety.overlayState.body.contains("未调用 " + "Apple Translation"),
            "live safety state never claims Apple was not called"
        )
    }

    @MainActor
    private static func testVariableLiveSuccessAndElapsedBounds() {
        withCapabilities { lease, receipt in
            let variableTargets = [
                "今天天气很好。",
                "今日天气宜人。\n适合散步。\t",
                "A different valid Apple result",
            ]
            for target in variableTargets {
                let decision = map(
                    envelope(
                        lease: lease,
                        receipt: receipt,
                        outcome: success(target)
                    ),
                    expectedLease: lease,
                    expectedReceipt: receipt
                )
                guard let presentation = presented(
                    decision,
                    "variable real Apple output presents"
                ) else { continue }
                expect(presentation.category == .success, "valid output is success")
                expect(
                    presentation.overlayState.title
                        == "Apple Translation 真实译文",
                    "success title is exact"
                )
                expect(presentation.overlayState.body == target, "full target is visible")
                expect(
                    presentation.overlayState.copyText == target,
                    "full variable target is retained for explicit copy"
                )
                expect(
                    presentation.overlayState.metadata
                        == "Debug 固定样例 · 真实 Apple Translation · 本机处理 · 实际耗时 218 毫秒",
                    "success metadata is exact"
                )
                expect(
                    presentation.overlayState.terminalAnnouncement?
                        .contains(target) == false,
                    "terminal announcement does not read the translation"
                )
                expect(presentation.overlayState.cta == nil, "success has no CTA")
                expect(
                    presentation.overlayState.truncationBadge == nil,
                    "fixed live fixture never displays truncation"
                )
            }

            for elapsed in [0, 12_000] {
                let decision = map(
                    envelope(
                        lease: lease,
                        receipt: receipt,
                        outcome: success("边界有效"),
                        elapsed: elapsed
                    ),
                    expectedLease: lease,
                    expectedReceipt: receipt
                )
                guard let presentation = presented(
                    decision,
                    "inclusive elapsed boundary succeeds"
                ) else { continue }
                expect(
                    presentation.overlayState.metadata?
                        .contains("实际耗时 \(elapsed) 毫秒") == true,
                    "actual elapsed boundary is disclosed"
                )
            }
        }
    }

    @MainActor
    private static func testGenerationLeaseReceiptAndCancellationDrop() {
        let registry = NativeTranslationOverlayExternalPresentationRegistry()
        let staleLease = registry.begin(sessionGeneration: 1) { _ in }
        let currentLease = registry.begin(sessionGeneration: 2) { _ in }
        let receiptRegistry = NativeTranslationAppleResultLabHostReceiptRegistry()
        guard let receipt = receiptRegistry.claim(
            runID: 17,
            claimGeneration: 23
        ), let otherReceipt = receiptRegistry.claim(
            runID: 17,
            claimGeneration: 24
        ) else {
            expect(false, "distinct host claims mint distinct receipts")
            return
        }
        expect(
            receiptRegistry.claim(runID: 17, claimGeneration: 23) == nil,
            "duplicate host claim cannot mint another receipt"
        )
        let unrelatedRegistry = NativeTranslationAppleResultLabHostReceiptRegistry()
        guard let unrelatedReceipt = unrelatedRegistry.claim(
            runID: 17,
            claimGeneration: 23
        ) else {
            expect(false, "independent registry can issue its own capability")
            return
        }
        expect(
            unrelatedReceipt != receipt,
            "another registry cannot forge the broker receipt with copied IDs"
        )
        let value = envelope(
            lease: currentLease,
            receipt: receipt,
            outcome: success("当前结果")
        )
        expect(
            map(
                value,
                expectedGeneration: 42,
                expectedLease: currentLease,
                expectedReceipt: receipt
            ) == .drop,
            "stale domain generation drops silently"
        )
        expect(
            map(
                value,
                expectedLease: staleLease,
                expectedReceipt: receipt
            ) == .drop,
            "stale overlay lease drops silently"
        )
        expect(
            map(
                value,
                expectedLease: currentLease,
                expectedReceipt: otherReceipt
            ) == .drop,
            "wrong host receipt drops silently"
        )
        expect(
            map(
                envelope(
                    lease: currentLease,
                    receipt: receipt,
                    outcome: .cancelled
                ),
                expectedLease: currentLease,
                expectedReceipt: receipt
            ) == .drop,
            "current cancellation drops silently"
        )
    }

    @MainActor
    private static func testStrictLiveSafetyMatrix() {
        withCapabilities { lease, receipt in
            let invalidEnvelopes: [NativeTranslationAppleResultLabEnvelope] = [
                envelope(
                fixture: .unrecognized,
                    lease: lease,
                    receipt: receipt,
                    outcome: success("结果")
                ),
                envelope(
                    provenance: .unverified,
                    lease: lease,
                    receipt: receipt,
                    outcome: success("结果")
                ),
                envelope(
                    requestedEngine: .volc,
                    lease: lease,
                    receipt: receipt,
                    outcome: success("结果")
                ),
                envelope(
                    lease: lease,
                    receipt: receipt,
                    outcome: success("结果"),
                    elapsed: -1
                ),
                envelope(
                    lease: lease,
                    receipt: receipt,
                    outcome: success("结果"),
                    elapsed: 12_001
                ),
                envelope(
                    lease: lease,
                    receipt: receipt,
                    outcome: success("结果"),
                    truncated: true
                ),
                envelope(
                    lease: lease,
                    receipt: receipt,
                    outcome: .skipped(.tooShort)
                ),
                envelope(
                    lease: lease,
                    receipt: receipt,
                    outcome: .failure(.emptyInput)
                ),
                envelope(
                    lease: lease,
                    receipt: receipt,
                    outcome: .failure(.volcNetwork)
                ),
                envelope(
                    lease: lease,
                    receipt: receipt,
                    outcome: .success(
                        NativeTranslationSuccess(
                            engine: .volc,
                            text: "错误引擎",
                            inputWasTruncated: false
                        )
                    )
                ),
                envelope(
                    lease: lease,
                    receipt: receipt,
                    outcome: .success(
                        NativeTranslationSuccess(
                            engine: .apple,
                            text: "结果",
                            inputWasTruncated: true
                        )
                    )
                ),
            ]
            for value in invalidEnvelopes {
                expect(
                    isSafety(
                        map(
                            value,
                            expectedLease: lease,
                            expectedReceipt: receipt
                        )
                    ),
                    "wrong fixture/engine/provenance/timing/truncation/outcome fails safe"
                )
            }

            let invalidBodies = [
                "",
                "   \n\t",
                "ok\u{0000}",
                "ok\r",
                "ok\u{007F}",
                "ok\u{0080}",
                String(repeating: "a", count: 20_001),
            ]
            for body in invalidBodies {
                let decision = map(
                    envelope(
                        lease: lease,
                        receipt: receipt,
                        outcome: success(body)
                    ),
                    expectedLease: lease,
                    expectedReceipt: receipt
                )
                expect(isSafety(decision), "invalid live body fails safe")
                guard let presentation = presented(
                    decision,
                    "invalid body produces visible safety state"
                ) else { continue }
                expect(
                    !presentation.overlayState.body.contains(body),
                    "invalid body is neither shown nor retained"
                )
            }
        }
    }

    @MainActor
    private static func testAppleTypedFailureMapping() {
        withCapabilities { lease, receipt in
            let cases: [(
                NativeTranslationFailure,
                NativeTranslationOverlayState.Kind,
                String
            )] = [
                (.appleNeedsPreparation, .notice, "Apple 语言包尚未准备"),
                (.appleUnsupported, .notice, "Apple Translation 不支持此语言对"),
                (.appleTemporarilyUnavailable, .error, "Apple Translation 暂时不可用"),
                (.appleExecutionFailed, .error, "Apple Translation 未能完成"),
            ]
            for (failure, kind, title) in cases {
                let decision = map(
                    envelope(
                        lease: lease,
                        receipt: receipt,
                        outcome: .failure(failure)
                    ),
                    expectedLease: lease,
                    expectedReceipt: receipt
                )
                guard let presentation = presented(
                    decision,
                    "Apple typed failure presents"
                ) else { continue }
                expect(presentation.overlayState.kind == kind, "failure kind is typed")
                expect(presentation.overlayState.title == title, "failure title is typed")
                expect(presentation.overlayState.copyText == nil, "failure has zero copy")
                expect(presentation.overlayState.cta == nil, "failure has zero CTA")
                expect(
                    presentation.overlayState.terminalAnnouncement?
                        .contains(presentation.overlayState.body) == false,
                    "failure announcement does not read its body"
                )
            }
        }
    }

    @MainActor
    private static func testCapabilitiesAndEnvelopeAreRedacted() {
        withCapabilities { lease, receipt in
            let secretTarget = "TARGET-CANARY-937"
            let receiptText = String(describing: receipt)
            let receiptDebug = String(reflecting: receipt)
            expect(receiptText.contains("17") == false, "receipt hides run identity")
            expect(receiptText.contains("23") == false, "receipt hides claim identity")
            expect(receiptDebug == receiptText, "receipt reflection is redacted")

            let value = envelope(
                lease: lease,
                receipt: receipt,
                outcome: success(secretTarget)
            )
            expect(
                value.description.contains(secretTarget) == false,
                "envelope description never reveals live target"
            )
            expect(
                value.debugDescription == value.description,
                "envelope reflection uses the redacted description"
            )
            expect(
                value.description.contains("hostReceipt: [REDACTED]"),
                "envelope redacts the host capability"
            )
            expect(
                value.description.contains(lease.description) == false,
                "envelope does not embed lease identity"
            )
        }
    }

    private static func testCopyAnnouncementsAreTruthfulAndRedacted() {
        expect(
            NativeTranslationAppleResultLabCopyAnnouncementPolicy.message(
                for: .copied
            ) == "句译，已复制 Debug 固定样例 Apple Translation 真实译文",
            "successful copy has one fixed real-Apple announcement"
        )
        let failure = NativeTranslationAppleResultLabCopyAnnouncementPolicy.message(
            for: .failed
        )
        expect(
            failure == "句译，复制失败；系统剪贴板内容可能已改变",
            "failed copy warns that clipboard state cannot be restored"
        )
        expect(
            failure.contains(NativeTranslationAppleResultLabFixtureID.appleFixedSample.rawValue)
                == false,
            "failed copy announcement contains no source or result"
        )
    }

    @MainActor
    private static func testLoadingAnnouncementsAreCurrentAndOncePerStage() {
        var lifecycle = NativeTranslationAppleResultLabLoadingAnnouncementLifecycle()
        expect(
            lifecycle.consume(stage: .initial, generation: 7, isCurrent: true)
                == "句译，正在运行 Debug 固定样例 Apple Translation",
            "live activation announces one concise initial state"
        )
        expect(
            lifecycle.consume(stage: .initial, generation: 7, isCurrent: true) == nil,
            "repeated initial rendering does not speak twice"
        )
        expect(
            lifecycle.consume(stage: .extended, generation: 7, isCurrent: true)
                == "句译，Debug 固定样例 Apple Translation 仍在处理中",
            "first slow update announces once"
        )
        expect(
            lifecycle.consume(stage: .extended, generation: 7, isCurrent: true) == nil,
            "repeated slow updates remain silent"
        )
        expect(
            lifecycle.consume(stage: .extended, generation: 6, isCurrent: false) == nil,
            "stale generation cannot reset or announce"
        )
        lifecycle.invalidate()
        expect(
            lifecycle.consume(stage: .initial, generation: 7, isCurrent: false) == nil,
            "dismissed lease cannot announce late"
        )
        expect(
            lifecycle.consume(stage: .initial, generation: 8, isCurrent: true) != nil,
            "a new current lease receives its own initial announcement"
        )

        let registry = NativeTranslationOverlayExternalPresentationRegistry()
        let terminalLease = registry.begin(sessionGeneration: 21) { _ in }
        var terminalLifecycle =
            NativeTranslationAppleResultLabLoadingAnnouncementLifecycle()
        expect(
            terminalLifecycle.consume(
                stage: .initial,
                generation: 21,
                isCurrent: registry.isCurrent(
                    terminalLease,
                    sessionGeneration: 21
                )
            ) != nil,
            "current live lease announces before terminal"
        )
        expect(
            registry.acceptTerminal(terminalLease, sessionGeneration: 21),
            "test consumes the exact terminal capability"
        )
        expect(
            !registry.isCurrent(terminalLease, sessionGeneration: 21),
            "terminal-consumed lease is no longer loading-current"
        )
        expect(
            terminalLifecycle.consume(
                stage: .extended,
                generation: 21,
                isCurrent: registry.isCurrent(
                    terminalLease,
                    sessionGeneration: 21
                )
            ) == nil,
            "late slow update after terminal has zero announcement"
        )
    }

    @MainActor
    static func main() {
        testExactStaticPresentations()
        testVariableLiveSuccessAndElapsedBounds()
        testGenerationLeaseReceiptAndCancellationDrop()
        testStrictLiveSafetyMatrix()
        testAppleTypedFailureMapping()
        testCapabilitiesAndEnvelopeAreRedacted()
        testCopyAnnouncementsAreTruthfulAndRedacted()
        testLoadingAnnouncementsAreCurrentAndOncePerStage()
        print(
            "NativeTranslationAppleResultLabBindingPresentationTests: \(passed) passed"
        )
    }
}
#endif
