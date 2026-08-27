import ApplicationServices
import Foundation

@main
enum NativeSelectionReaderTests {
    private static let source = NativeSelectionTarget(
        processIdentifier: 200,
        bundleIdentifier: "com.example.editor"
    )

    private final class StubClient: NativeSelectionAXClient {
        var isTrusted = true
        var currentProcessIdentifier: pid_t = 100
        var frontmostApplication: NativeSelectionTarget? = source
        var response: NativeSelectionAXRead = .text("hello")
        var beforeReturningSelection: (() -> Void)?
        private(set) var requestedTargets: [NativeSelectionTarget] = []

        func copySelectedText(
            from target: NativeSelectionTarget
        ) -> NativeSelectionAXRead {
            requestedTargets.append(target)
            beforeReturningSelection?()
            return response
        }
    }

    private static var passed = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
        passed += 1
    }

    private static func testTargetAndPermissionGuards() {
        let ownClient = StubClient()
        let ownReader = NativeSelectionReader(client: ownClient)
        let ownTarget = NativeSelectionTarget(
            processIdentifier: 100,
            bundleIdentifier: "io.github.Eim-aa.Juyi"
        )
        expect(
            ownReader.readSelection(for: ownTarget) == .cancelled,
            "the app can never read its own focused field"
        )
        expect(ownClient.requestedTargets.isEmpty, "own PID is rejected before AX")

        let invalidClient = StubClient()
        let invalidReader = NativeSelectionReader(client: invalidClient)
        expect(
            invalidReader.readSelection(
                for: .init(processIdentifier: 0, bundleIdentifier: nil)
            ) == .cancelled,
            "invalid PID is cancelled"
        )

        let deniedClient = StubClient()
        deniedClient.isTrusted = false
        let deniedReader = NativeSelectionReader(client: deniedClient)
        expect(
            deniedReader.readSelection(for: source) == .accessibilityRequired,
            "missing Accessibility permission is structured"
        )
        expect(deniedClient.requestedTargets.isEmpty, "denied reads do not call AX")

        let switchedClient = StubClient()
        switchedClient.frontmostApplication = NativeSelectionTarget(
            processIdentifier: 300,
            bundleIdentifier: "com.example.settings"
        )
        let switchedReader = NativeSelectionReader(client: switchedClient)
        expect(
            switchedReader.readSelection(for: source) == .cancelled,
            "PID focus races are cancelled"
        )
        expect(switchedClient.requestedTargets.isEmpty, "PID mismatch stops before AX")

        let switchedDuringReadClient = StubClient()
        switchedDuringReadClient.beforeReturningSelection = {
            switchedDuringReadClient.frontmostApplication = NativeSelectionTarget(
                processIdentifier: 300,
                bundleIdentifier: "com.example.other"
            )
        }
        let switchedDuringReadReader = NativeSelectionReader(
            client: switchedDuringReadClient
        )
        expect(
            switchedDuringReadReader.readSelection(for: source) == .cancelled,
            "a frontmost PID switch during synchronous AX cancels captured text"
        )
        expect(
            switchedDuringReadClient.requestedTargets == [source],
            "post-AX identity check happens after the bounded read"
        )

        let reusedPIDClient = StubClient()
        reusedPIDClient.frontmostApplication = NativeSelectionTarget(
            processIdentifier: 200,
            bundleIdentifier: "com.example.different-process"
        )
        let reusedPIDReader = NativeSelectionReader(client: reusedPIDClient)
        expect(
            reusedPIDReader.readSelection(for: source)
                == .success(text: "hello", didTruncate: false),
            "PID is the security key while bundle identity remains snapshot metadata"
        )
    }

    private static func testNormalizationAndLengthPolicy() {
        let client = StubClient()
        client.response = .text("  first\r\nsecond\rthird \n")
        let reader = NativeSelectionReader(client: client)
        expect(
            reader.readSelection(for: source)
                == .success(text: "first\nsecond\nthird", didTruncate: false),
            "line endings and Unicode edge whitespace are normalized"
        )
        expect(client.requestedTargets == [source], "capture is bound to trigger identity")

        let whitespaceClient = StubClient()
        whitespaceClient.response = .text("\u{2003}\r\n\t\u{00a0}")
        let whitespaceReader = NativeSelectionReader(client: whitespaceClient)
        expect(
            whitespaceReader.readSelection(for: source) == .noSelection,
            "Unicode whitespace-only selection is empty"
        )

        let interiorClient = StubClient()
        interiorClient.response = .text(" A\t B\nCafe\u{301} ")
        let interiorReader = NativeSelectionReader(client: interiorClient)
        expect(
            interiorReader.readSelection(for: source)
                == .success(text: "A\t B\nCafe\u{301}", didTruncate: false),
            "interior text and decomposed Unicode are unchanged"
        )

        let exactClient = StubClient()
        exactClient.response = .text(String(repeating: "a", count: 5_000))
        let exactReader = NativeSelectionReader(client: exactClient)
        expect(
            exactReader.readSelection(for: source)
                == .success(text: String(repeating: "a", count: 5_000), didTruncate: false),
            "exact maximum is not truncated"
        )

        let longClient = StubClient()
        longClient.response = .text(String(repeating: "😀", count: 5_001))
        let longReader = NativeSelectionReader(client: longClient)
        let longResult = longReader.readSelection(for: source)
        if case let .success(text, didTruncate) = longResult {
            expect(text.unicodeScalars.count == 5_000, "Unicode scalars are capped safely")
            expect(didTruncate, "over-limit selection records truncation")
        } else {
            expect(false, "long text should return success")
        }
    }

    private static func testStableAXOutcomes() {
        let cases: [(NativeSelectionAXRead, NativeSelectionResult, String)] = [
            (.accessibilityRequired, .accessibilityRequired, "revoked permission propagates"),
            (.noFocusedElement, .noFocusedElement, "missing focus stays distinct"),
            (.noSelection, .noSelection, "AX no-value is no selection"),
            (.unsupported, .unsupported, "unsupported AX element is distinct"),
            (.secureField, .secureField, "secure field is fail-closed"),
            (
                .temporarilyUnavailable,
                .temporarilyUnavailable,
                "transient AX failure stays retryable"
            ),
            (.internalFailure, .internalFailure, "internal AX failure is stable"),
            (.cancelled, .cancelled, "stale work is cancelled"),
        ]
        for (response, expected, message) in cases {
            let client = StubClient()
            client.response = response
            let reader = NativeSelectionReader(client: client)
            expect(reader.readSelection(for: source) == expected, message)
        }
    }

    private static func testPureAXErrorAndSecurityPolicy() {
        let tables: [(
            NativeSelectionAXPolicy.Stage,
            [(AXError, NativeSelectionAXPolicy.Decision)]
        )] = [
            (
                .focusedElement,
                [
                    (.success, .proceed),
                    (.apiDisabled, .finish(.accessibilityRequired)),
                    (.noValue, .finish(.noFocusedElement)),
                    (.attributeUnsupported, .finish(.unsupported)),
                    (.notImplemented, .finish(.unsupported)),
                    (.invalidUIElement, .finish(.temporarilyUnavailable)),
                    (.cannotComplete, .finish(.temporarilyUnavailable)),
                    (.illegalArgument, .finish(.internalFailure)),
                ]
            ),
            (
                .selectedText,
                [
                    (.success, .proceed),
                    (.apiDisabled, .finish(.accessibilityRequired)),
                    (.noValue, .finish(.noSelection)),
                    (.attributeUnsupported, .finish(.unsupported)),
                    (.notImplemented, .finish(.unsupported)),
                    (.invalidUIElement, .finish(.temporarilyUnavailable)),
                    (.cannotComplete, .finish(.temporarilyUnavailable)),
                    (.failure, .finish(.internalFailure)),
                ]
            ),
            (
                .subrole,
                [
                    (.success, .proceed),
                    (.noValue, .proceed),
                    (.attributeUnsupported, .proceed),
                    (.apiDisabled, .finish(.accessibilityRequired)),
                    (.notImplemented, .finish(.unsupported)),
                    (.invalidUIElement, .finish(.temporarilyUnavailable)),
                    (.cannotComplete, .finish(.temporarilyUnavailable)),
                    (.illegalArgument, .finish(.internalFailure)),
                ]
            ),
            (
                .elementIdentity,
                [
                    (.success, .proceed),
                    (.apiDisabled, .finish(.accessibilityRequired)),
                    (.invalidUIElement, .finish(.temporarilyUnavailable)),
                    (.cannotComplete, .finish(.temporarilyUnavailable)),
                    (.illegalArgument, .finish(.cancelled)),
                ]
            ),
            (
                .timeoutConfiguration,
                [
                    (.success, .proceed),
                    (.apiDisabled, .finish(.accessibilityRequired)),
                    (.invalidUIElement, .finish(.temporarilyUnavailable)),
                    (.cannotComplete, .finish(.temporarilyUnavailable)),
                    (.illegalArgument, .finish(.internalFailure)),
                ]
            ),
        ]
        for (stage, cases) in tables {
            for (error, expected) in cases {
                expect(
                    NativeSelectionAXPolicy.decision(for: error, stage: stage)
                        == expected,
                    "AX error mapping is stable for \(stage) / \(error.rawValue)"
                )
            }
        }

        expect(
            NativeSelectionAXPolicy.identityDecision(
                elementProcessIdentifier: 200,
                targetProcessIdentifier: 200
            ) == .proceed,
            "matching AX element PID proceeds"
        )
        expect(
            NativeSelectionAXPolicy.identityDecision(
                elementProcessIdentifier: 300,
                targetProcessIdentifier: 200
            ) == .finish(.cancelled),
            "mismatched AX element PID cancels"
        )
        expect(
            NativeSelectionAXPolicy.subroleDecision(
                kAXSecureTextFieldSubrole as String
            ) == .finish(.secureField),
            "public secure-text subrole is blocked"
        )
        expect(
            NativeSelectionAXPolicy.subroleDecision("AXTextField") == .proceed,
            "ordinary text subrole proceeds"
        )
        expect(
            NativeSelectionAXPolicy.subroleDecision("password hint") == .proceed,
            "unofficial string heuristics are not used"
        )
    }

    static func main() {
        testTargetAndPermissionGuards()
        testNormalizationAndLengthPolicy()
        testStableAXOutcomes()
        testPureAXErrorAndSecurityPolicy()
        print("NativeSelectionReaderTests: \(passed) passed")
    }
}
