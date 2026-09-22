import Foundation

@main
enum NativeTranslationOverlayModelTests {
    private final class ManualClock {
        private final class Entry {
            let deadline: TimeInterval
            let action: () -> Void
            var cancelled = false

            init(deadline: TimeInterval, action: @escaping () -> Void) {
                self.deadline = deadline
                self.action = action
            }
        }

        private var entries: [Entry] = []
        private(set) var now: TimeInterval = 0

        var clock: NativeTranslationOverlayClock {
            NativeTranslationOverlayClock { [weak self] delay, action in
                guard let self else {
                    return NativeTranslationOverlayScheduledTask {}
                }
                let entry = Entry(deadline: self.now + delay, action: action)
                self.entries.append(entry)
                return NativeTranslationOverlayScheduledTask {
                    entry.cancelled = true
                }
            }
        }

        func advance(to target: TimeInterval) {
            precondition(target >= now)
            while let next = entries
                .filter({ !$0.cancelled && $0.deadline <= target })
                .min(by: { $0.deadline < $1.deadline }) {
                next.cancelled = true
                now = next.deadline
                next.action()
            }
            now = target
        }

        var activeTaskCount: Int {
            entries.filter { !$0.cancelled }.count
        }
    }

    private static var passed = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
        passed += 1
    }

    private static func response(
        requested: NativeTranslationOverlayEngine = .apple,
        actual: NativeTranslationOverlayEngine? = .apple,
        result: String? = "完整译文\n第二行",
        elapsed: Double? = 218,
        error: NativeTranslationOverlayBackendError? = nil,
        warning: NativeTranslationOverlayResponseWarning? = nil,
        captureTruncated: Bool = false,
        responseTruncated: Bool = false,
        inputTruncated: Bool = false
    ) -> NativeTranslationOverlayResponse {
        NativeTranslationOverlayResponse(
            requestedEngine: requested,
            actualEngine: actual,
            result: result,
            elapsedMilliseconds: elapsed,
            error: error,
            warning: warning,
            captureDidTruncate: captureTruncated,
            responseTruncated: responseTruncated,
            inputTruncated: inputTruncated
        )
    }

    private static func testCaptureStateMatrix() {
        let cases: [(
            NativeTranslationOverlayCaptureStatus,
            NativeTranslationOverlayState.Kind,
            String,
            NativeTranslationOverlayCTA?
        )] = [
            (.noSelection, .notice, "没有检测到选中文字", nil),
            (.secureField, .notice, "安全输入框不会被读取", nil),
            (.unsupported, .notice, "此 App 暂不支持直接取词", nil),
            (.accessibilityRequired, .error, "需要开启辅助功能权限", .openJuyi),
            (.noFocusedElement, .notice, "暂时无法读取选中文字", nil),
            (.temporarilyUnavailable, .notice, "暂时无法读取选中文字", nil),
        ]
        for (capture, kind, title, cta) in cases {
            let state = NativeTranslationOverlayReducer.reduce(.capture(capture))
            expect(state.kind == kind, "capture kind is stable for \(capture)")
            expect(state.title == title, "capture title is stable for \(capture)")
            expect(state.cta == cta, "capture CTA policy is stable for \(capture)")
            expect(!state.canCopy && state.copyText == nil, "capture states never copy")
        }
        let cancelled = NativeTranslationOverlayReducer.reduce(.capture(.cancelled))
        expect(cancelled == .hidden, "cancelled is silent with zero panel state")
    }

    private static func testSuccessPrivacyEngineMatrix() {
        let apple = NativeTranslationOverlayReducer.reduce(
            .response(response())
        )
        expect(apple.kind == .success, "Apple→Apple succeeds")
        expect(apple.metadata == "Apple 离线 · 218 毫秒", "Apple footer is exact")
        expect(apple.copyText == "完整译文\n第二行", "copy preserves full result")
        expect(apple.fallbackNotice == nil, "normal success has no fallback warning")

        let volc = NativeTranslationOverlayReducer.reduce(
            .response(response(requested: .volc, actual: .volc, elapsed: 9))
        )
        expect(volc.kind == .success, "Volc→Volc succeeds")
        expect(volc.metadata == "火山云端 · 9 毫秒", "Volc footer is exact")

        let legalFallback = NativeTranslationOverlayReducer.reduce(
            .response(
                response(
                    requested: .volc,
                    actual: .apple,
                    warning: .usedAppleFallback
                )
            )
        )
        expect(legalFallback.kind == .success, "explicit Volc→Apple fallback succeeds")
        expect(
            legalFallback.fallbackNotice == "已改用 Apple 离线",
            "fallback warning is explicit"
        )

        for unsafe in [
            response(requested: .apple, actual: .volc),
            response(requested: .apple, actual: .volc, warning: .usedAppleFallback),
            response(requested: .volc, actual: .apple),
            response(requested: .apple, actual: .apple, warning: .usedAppleFallback),
            response(actual: nil),
        ] {
            let state = NativeTranslationOverlayReducer.reduce(.response(unsafe))
            expect(state.kind == .error, "unexplained engine state fails closed")
            expect(state.title == "没有收到译文", "engine mismatch is non-echoing")
            expect(state.copyText == nil && !state.body.contains("完整译文"), "unsafe result is dropped")
            expect(state.cta == .openDiagnostics, "engine mismatch has one diagnostics CTA")
        }
    }

    private static func testMalformedAndErrorPrivacy() {
        for elapsed in [Double.nan, Double.infinity, -1, 1.5] {
            let state = NativeTranslationOverlayReducer.reduce(
                .response(response(elapsed: elapsed))
            )
            expect(state.kind == .error, "invalid elapsed fails closed")
            expect(state.copyText == nil, "invalid elapsed retains no result")
        }
        for malformed in [
            response(result: nil),
            response(result: " \n\t "),
            response(elapsed: nil),
        ] {
            let state = NativeTranslationOverlayReducer.reduce(.response(malformed))
            expect(state.title == "没有收到译文", "empty/missing fields are malformed")
            expect(state.copyText == nil, "malformed response cannot copy")
        }

        let rawSecret = "UPSTREAM SECRET localizedDescription AK/SK"
        let errors: [NativeTranslationOverlayBackendError] = [
            .serviceUnavailable, .requestTimeout, .httpFailure, .authenticationFailure,
            .appleNotReady, .appleUnsupported, .appleFailed, .appleTimedOut,
            .volcCredential, .volcNetwork, .volcTimeout,
            .sourceLanguageMismatch, .noEngine, .malformedResponse, .emptyResult,
        ]
        for error in errors {
            let state = NativeTranslationOverlayReducer.reduce(
                .response(response(result: rawSecret, error: error))
            )
            expect(state.kind == .error || state.kind == .notice, "typed errors are terminal")
            expect(!state.body.contains(rawSecret), "backend echo never enters error UI")
            expect(state.copyText == nil && !state.canCopy, "error result is never copyable")
            expect(state.cta == nil || state.cta?.title.isEmpty == false, "at most one typed CTA")
        }
    }

    private static func testErrorCopyAndTruncationPolicy() {
        let service = NativeTranslationOverlayReducer.reduce(
            .response(response(error: .requestTimeout))
        )
        expect(service.title == "翻译组件没有响应", "service timeout title is exact")
        expect(service.cta == .openDiagnostics, "service timeout offers diagnostics")
        let apple = NativeTranslationOverlayReducer.reduce(
            .response(response(error: .appleNotReady))
        )
        expect(apple.cta == .prepareAppleLanguages, "Apple error offers preparation")
        for error in [NativeTranslationOverlayBackendError.appleFailed, .appleTimedOut, .appleUnsupported] {
            let native = NativeTranslationOverlayReducer.reduce(.response(response(error: error)))
            expect(native.cta == .openDiagnostics, "native Apple failure offers its own diagnostics")
            expect(!native.body.contains("自动修复"), "native Apple failure never requests Python service repair")
            expect(native.title.contains("Apple"), "native Apple error identifies the system engine")
        }
        let timeout = NativeTranslationOverlayReducer.reduce(.timeout)
        expect(timeout.title == "翻译超时", "shared panel timeout does not misdiagnose a missing service")
        expect(!timeout.body.contains("自动修复"), "panel timer does not request Python repair")
        let volcCredential = NativeTranslationOverlayReducer.reduce(
            .response(response(error: .volcCredential))
        )
        expect(volcCredential.cta == .checkCloudSettings, "credential error offers cloud settings")
        let volcNetwork = NativeTranslationOverlayReducer.reduce(
            .response(response(error: .volcNetwork))
        )
        expect(volcNetwork.cta == nil, "Volc network error has no CTA")
        let mismatch = NativeTranslationOverlayReducer.reduce(
            .response(response(error: .sourceLanguageMismatch))
        )
        expect(mismatch.cta == nil, "source mismatch has no CTA")
        let noEngine = NativeTranslationOverlayReducer.reduce(
            .response(response(error: .noEngine))
        )
        expect(noEngine.cta == .chooseEngine, "no-engine offers one engine CTA")

        for flags in [(true, false, false), (false, true, false), (false, false, true)] {
            let state = NativeTranslationOverlayReducer.reduce(
                .response(
                    response(
                        captureTruncated: flags.0,
                        responseTruncated: flags.1,
                        inputTruncated: flags.2
                    )
                )
            )
            expect(state.truncationBadge == "原文已截断", "all truncation sources OR together")
            expect(
                state.truncationAccessibilityHelp == "仅翻译原文前 5000 个 Unicode 标量",
                "truncation help is exact"
            )
        }
        let normal = NativeTranslationOverlayReducer.reduce(.response(response()))
        expect(normal.truncationBadge == nil, "viewport overflow is not input truncation")
    }

    private static func testInjectableClockAndGeneration() {
        let clock = ManualClock()
        var updates: [(Int, NativeTranslationOverlayState)] = []
        let session = NativeTranslationOverlaySession(clock: clock.clock) {
            updates.append(($0, $1))
        }

        let first = session.begin()
        expect(session.state == .hidden, "loading is delayed")
        expect(clock.activeTaskCount == 3, "one session owns all loading deadlines")
        clock.advance(to: 0.149)
        expect(session.state == .hidden, "149ms stays hidden")
        clock.advance(to: 0.150)
        expect(session.state.kind == .loading && session.state.body.isEmpty, "150ms shows loading")
        clock.advance(to: 1.999)
        expect(session.state.body.isEmpty, "1999ms has no extended message")
        clock.advance(to: 2.0)
        expect(session.state.body == "仍在翻译，请稍候…", "2000ms updates in place")
        clock.advance(to: 11.999)
        expect(session.state.kind == .loading, "11999ms remains loading")
        clock.advance(to: 12.0)
        expect(session.state.title == "翻译超时", "12000ms becomes error")
        expect(clock.activeTaskCount == 0, "terminal cancels every old deadline")

        session.resolve(.response(response(result: "迟到结果")), for: first)
        expect(session.state.title == "翻译超时", "late result cannot overwrite timeout")

        let fastClock = ManualClock()
        var fastVisibleKinds: [NativeTranslationOverlayState.Kind] = []
        let fast = NativeTranslationOverlaySession(clock: fastClock.clock) { _, state in
            if state.isVisible { fastVisibleKinds.append(state.kind) }
        }
        let fastGeneration = fast.begin()
        fastClock.advance(to: 0.05)
        fast.resolve(.response(response()), for: fastGeneration)
        expect(fastVisibleKinds == [.success], "fast terminal never flashes loading")
        fastClock.advance(to: 20)
        expect(fast.state.kind == .success, "cancelled timers cannot reopen or overwrite")

        let stale = fast.begin()
        let latest = fast.begin()
        fast.resolve(.response(response(result: "旧")), for: stale)
        expect(fast.state == .hidden, "old generation cannot update")
        fast.resolve(.response(response(result: "新")), for: latest)
        expect(fast.state.copyText == "新", "latest generation wins")
        fast.resolve(.response(response(result: "同代第二终态")), for: latest)
        expect(fast.state.copyText == "新", "one generation accepts only one terminal")

        let beforeInvalidate = fast.generation
        fast.invalidate()
        expect(fast.generation == beforeInvalidate + 1, "dismiss advances generation")
        expect(fast.state == .hidden && fastClock.activeTaskCount == 0, "dismiss is silent and cancels")

        expect(updates.filter { $0.1.isTerminal }.count == 1, "first timeline emitted one terminal")
    }

    private static func testCopyEffectIsExactAndGenerationBound() {
        let exact = "  完整 fixture 译文\n第二行 😀 " + String(repeating: "长", count: 8_000)
        let success = NativeTranslationOverlayReducer.reduce(
            .response(response(result: exact))
        )
        var writes: [String] = []
        let copied = NativeTranslationOverlayCopyPolicy.copy(
            state: success,
            stateGeneration: 7,
            currentGeneration: 7,
            isVisible: true,
            writer: { writes.append($0); return true }
        )
        expect(copied == .copied, "current visible success can copy")
        expect(writes == [exact], "copy preserves exact Unicode/newlines/length")

        for (state, stateGeneration, currentGeneration, visible) in [
            (NativeTranslationOverlayState.hidden, 7, 7, true),
            (NativeTranslationOverlayReducer.reduce(.loading(isExtended: false)), 7, 7, true),
            (NativeTranslationOverlayReducer.reduce(.capture(.secureField)), 7, 7, true),
            (success, 6, 7, true),
            (success, 7, 7, false),
        ] {
            let before = writes.count
            let result = NativeTranslationOverlayCopyPolicy.copy(
                state: state,
                stateGeneration: stateGeneration,
                currentGeneration: currentGeneration,
                isVisible: visible,
                writer: { writes.append($0); return true }
            )
            expect(result == .unavailable, "non-success/stale/hidden copy is unavailable")
            expect(writes.count == before, "unavailable copy performs zero writes")
        }

        let failed = NativeTranslationOverlayCopyPolicy.copy(
            state: success,
            stateGeneration: 7,
            currentGeneration: 7,
            isVisible: true,
            writer: { _ in false }
        )
        expect(failed == .failed, "writer failure stays visible for retry")
    }

    private static func testTerminalAnnouncementGate() {
        let success = NativeTranslationOverlayReducer.reduce(
            .response(response(result: "fixture"))
        )
        expect(
            NativeTranslationOverlayAnnouncementPolicy.shouldAnnounceTerminal(
                state: success,
                stateGeneration: 9,
                currentGeneration: 9,
                panelIsVisible: true,
                announcedGeneration: nil
            ),
            "current visible terminal announces once"
        )
        expect(
            !NativeTranslationOverlayAnnouncementPolicy.shouldAnnounceTerminal(
                state: success,
                stateGeneration: 8,
                currentGeneration: 9,
                panelIsVisible: true,
                announcedGeneration: nil
            ),
            "late old generation never announces"
        )
        expect(
            !NativeTranslationOverlayAnnouncementPolicy.shouldAnnounceTerminal(
                state: success,
                stateGeneration: 9,
                currentGeneration: 9,
                panelIsVisible: false,
                announcedGeneration: nil
            ),
            "close/invalidate before presentation produces no announcement"
        )
        expect(
            !NativeTranslationOverlayAnnouncementPolicy.shouldAnnounceTerminal(
                state: .hidden,
                stateGeneration: 9,
                currentGeneration: 9,
                panelIsVisible: true,
                announcedGeneration: nil
            ),
            "cancelled/hidden state is silent"
        )
        expect(
            !NativeTranslationOverlayAnnouncementPolicy.shouldAnnounceTerminal(
                state: success,
                stateGeneration: 9,
                currentGeneration: 9,
                panelIsVisible: true,
                announcedGeneration: 9
            ),
            "same terminal generation cannot replay on relayout"
        )

        // A relayout may commit pending terminal before fade-in, or arrive
        // after swap but before the original fade completion. It announces;
        // the delayed original completion then sees the same generation and
        // cannot replay.
        var relayoutAnnouncementCount = 0
        var announcedGeneration: Int?
        if NativeTranslationOverlayAnnouncementPolicy.shouldAnnounceTerminal(
            state: success,
            stateGeneration: 10,
            currentGeneration: 10,
            panelIsVisible: true,
            announcedGeneration: announcedGeneration
        ) {
            announcedGeneration = 10
            relayoutAnnouncementCount += 1
        }
        if NativeTranslationOverlayAnnouncementPolicy.shouldAnnounceTerminal(
            state: success,
            stateGeneration: 10,
            currentGeneration: 10,
            panelIsVisible: true,
            announcedGeneration: announcedGeneration
        ) {
            relayoutAnnouncementCount += 1
        }
        expect(
            relayoutAnnouncementCount == 1,
            "pre/post-swap relayout plus delayed fade completion announces exactly once"
        )
    }

    static func main() {
        testCaptureStateMatrix()
        testSuccessPrivacyEngineMatrix()
        testMalformedAndErrorPrivacy()
        testErrorCopyAndTruncationPolicy()
        testInjectableClockAndGeneration()
        testCopyEffectIsExactAndGenerationBound()
        testTerminalAnnouncementGate()
        print("NativeTranslationOverlayModelTests: \(passed) passed")
    }
}
