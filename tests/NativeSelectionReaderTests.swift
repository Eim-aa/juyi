import ApplicationServices
import Foundation

@main
@MainActor
enum NativeSelectionReaderTests {
    nonisolated private static let sourceLaunchDate = Date(
        timeIntervalSinceReferenceDate: 1_000
    )
    nonisolated private static let source = NativeSelectionTarget(
        processIdentifier: 200,
        launchDate: sourceLaunchDate,
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
            launchDate: Date(timeIntervalSinceReferenceDate: 900),
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
                for: .init(
                    processIdentifier: 0,
                    launchDate: Date(timeIntervalSinceReferenceDate: 800),
                    bundleIdentifier: nil
                )
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
            launchDate: Date(timeIntervalSinceReferenceDate: 1_100),
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
                launchDate: Date(timeIntervalSinceReferenceDate: 1_200),
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

        let metadataChangedClient = StubClient()
        metadataChangedClient.frontmostApplication = NativeSelectionTarget(
            processIdentifier: 200,
            launchDate: sourceLaunchDate,
            bundleIdentifier: "com.example.different-process"
        )
        let metadataChangedReader = NativeSelectionReader(client: metadataChangedClient)
        expect(
            metadataChangedReader.readSelection(for: source)
                == .success(text: "hello", didTruncate: false),
            "bundle identity remains snapshot metadata"
        )

        let reusedPIDClient = StubClient()
        reusedPIDClient.frontmostApplication = NativeSelectionTarget(
            processIdentifier: 200,
            launchDate: Date(timeIntervalSinceReferenceDate: 2_000),
            bundleIdentifier: "com.example.editor"
        )
        let reusedPIDReader = NativeSelectionReader(client: reusedPIDClient)
        expect(
            reusedPIDReader.readSelection(for: source) == .cancelled,
            "same PID with a different launch date is a different process"
        )
        expect(
            reusedPIDClient.requestedTargets.isEmpty,
            "PID reuse is rejected before AX"
        )

        let reusedDuringReadClient = StubClient()
        reusedDuringReadClient.beforeReturningSelection = {
            reusedDuringReadClient.frontmostApplication = NativeSelectionTarget(
                processIdentifier: 200,
                launchDate: Date(timeIntervalSinceReferenceDate: 2_000),
                bundleIdentifier: "com.example.editor"
            )
        }
        let reusedDuringReadReader = NativeSelectionReader(
            client: reusedDuringReadClient
        )
        expect(
            reusedDuringReadReader.readSelection(for: source) == .cancelled,
            "PID reuse during synchronous AX is rejected by the post-read identity check"
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
                .role,
                [
                    (.success, .proceed),
                    (.noValue, .finish(.unsupported)),
                    (.attributeUnsupported, .finish(.unsupported)),
                    (.apiDisabled, .finish(.accessibilityRequired)),
                    (.notImplemented, .finish(.unsupported)),
                    (.invalidUIElement, .finish(.temporarilyUnavailable)),
                    (.cannotComplete, .finish(.temporarilyUnavailable)),
                    (.illegalArgument, .finish(.internalFailure)),
                ]
            ),
            (
                .subrole,
                [
                    (.success, .proceed),
                    (.noValue, .finish(.unsupported)),
                    (.attributeUnsupported, .finish(.unsupported)),
                    (.apiDisabled, .finish(.accessibilityRequired)),
                    (.notImplemented, .finish(.unsupported)),
                    (.invalidUIElement, .finish(.temporarilyUnavailable)),
                    (.cannotComplete, .finish(.temporarilyUnavailable)),
                    (.illegalArgument, .finish(.internalFailure)),
                ]
            ),
            (
                .focusedElementRevalidation,
                [
                    (.success, .proceed),
                    (.apiDisabled, .finish(.accessibilityRequired)),
                    (.noValue, .finish(.cancelled)),
                    (.attributeUnsupported, .finish(.cancelled)),
                    (.notImplemented, .finish(.cancelled)),
                    (.invalidUIElement, .finish(.temporarilyUnavailable)),
                    (.cannotComplete, .finish(.temporarilyUnavailable)),
                    (.illegalArgument, .finish(.cancelled)),
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
                elementProcessIdentity: source.processIdentity,
                targetProcessIdentity: source.processIdentity
            ) == .proceed,
            "matching AX process identity proceeds"
        )
        expect(
            NativeSelectionAXPolicy.identityDecision(
                elementProcessIdentity: NativeSelectionProcessIdentity(
                    processIdentifier: 200,
                    launchDate: Date(timeIntervalSinceReferenceDate: 2_000)
                ),
                targetProcessIdentity: source.processIdentity
            ) == .finish(.cancelled),
            "same AX PID with a different launch date cancels"
        )
        expect(
            NativeSelectionAXPolicy.identityDecision(
                elementProcessIdentity: nil,
                targetProcessIdentity: source.processIdentity
            ) == .finish(.cancelled),
            "missing AX process launch date cancels"
        )
        expect(
            NativeSelectionAXPolicy.focusedElementDecision(elementsMatch: true)
                == .proceed,
            "the same post-read focused element proceeds"
        )
        expect(
            NativeSelectionAXPolicy.focusedElementDecision(elementsMatch: false)
                == .finish(.cancelled),
            "a post-read focused element change cancels"
        )
        expect(
            NativeSelectionAXPolicy.roleAndSubroleValueDecision(
                roleValue: kAXTextFieldRole as CFString,
                subroleValue: nil
            )
                == .finish(.unsupported),
            "missing successful subrole value fails closed"
        )
        expect(
            NativeSelectionAXPolicy.roleAndSubroleValueDecision(
                roleValue: nil,
                subroleValue: kAXSearchFieldSubrole as CFString
            )
                == .finish(.unsupported),
            "missing successful role value fails closed"
        )
        expect(
            NativeSelectionAXPolicy.roleAndSubroleValueDecision(
                roleValue: NSNumber(value: 1),
                subroleValue: kAXSearchFieldSubrole as CFString
            )
                == .finish(.unsupported),
            "non-string role value fails closed"
        )
        expect(
            NativeSelectionAXPolicy.roleAndSubroleValueDecision(
                roleValue: kAXTextFieldRole as CFString,
                subroleValue: NSNumber(value: 1)
            )
                == .finish(.unsupported),
            "non-string subrole value fails closed"
        )
        expect(
            NativeSelectionAXPolicy.roleAndSubroleDecision(
                role: kAXTextFieldRole as String,
                subrole: kAXSecureTextFieldSubrole as String
            ) == .finish(.secureField),
            "public secure-text subrole is blocked"
        )
        expect(
            NativeSelectionAXPolicy.roleAndSubroleDecision(
                role: kAXTextFieldRole as String,
                subrole: kAXUnknownSubrole as String
            ) == .finish(.unsupported),
            "public unknown subrole is blocked"
        )
        expect(
            NativeSelectionAXPolicy.roleAndSubroleDecision(
                role: kAXUnknownRole as String,
                subrole: kAXSearchFieldSubrole as String
            ) == .finish(.unsupported),
            "public unknown role is blocked"
        )
        expect(
            NativeSelectionAXPolicy.roleAndSubroleDecision(
                role: kAXTextFieldRole as String,
                subrole: "AXCustomTextField"
            ) == .finish(.unsupported),
            "unreviewed custom subroles do not proceed"
        )
        expect(
            NativeSelectionAXPolicy.roleAndSubroleDecision(
                role: "",
                subrole: kAXSearchFieldSubrole as String
            ) == .finish(.unsupported),
            "empty role fails closed"
        )
        expect(
            NativeSelectionAXPolicy.roleAndSubroleDecision(
                role: kAXTextFieldRole as String,
                subrole: ""
            ) == .finish(.unsupported),
            "empty subrole fails closed"
        )
        expect(
            NativeSelectionAXPolicy.roleAndSubroleDecision(
                role: kAXTextFieldRole as String,
                subrole: kAXSearchFieldSubrole as String
            ) == .proceed,
            "the reviewed public non-secure role/subrole pair proceeds"
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
