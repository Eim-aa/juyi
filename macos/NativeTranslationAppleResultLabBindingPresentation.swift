#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
import Foundation

enum NativeTranslationAppleResultLabFixtureID: String, Equatable, Sendable {
    case appleFixedSample
    case unrecognized
}

/// Opaque proof that the exact SwiftUI Translation host claimed this run.
/// The capability has no public initializer and never exposes its identity.
struct NativeTranslationAppleResultLabHostReceipt: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    private let authorityID: UUID
    private let runID: UInt64
    private let claimGeneration: UInt64

    fileprivate init(
        authorityID: UUID,
        runID: UInt64,
        claimGeneration: UInt64
    ) {
        self.authorityID = authorityID
        self.runID = runID
        self.claimGeneration = claimGeneration
    }

    var description: String {
        "NativeTranslationAppleResultLabHostReceipt([REDACTED])"
    }

    var debugDescription: String { description }
}

enum NativeTranslationAppleResultLabHostReceiptAuthority {
    fileprivate static func mint(
        authorityID: UUID,
        runID: UInt64,
        claimGeneration: UInt64
    ) -> NativeTranslationAppleResultLabHostReceipt {
        NativeTranslationAppleResultLabHostReceipt(
            authorityID: authorityID,
            runID: runID,
            claimGeneration: claimGeneration
        )
    }
}

/// The SwiftUI host broker owns one registry. A logical host claim may obtain
/// its capability once; replaying the same claim generation fails closed.
@MainActor
final class NativeTranslationAppleResultLabHostReceiptRegistry {
    private struct ClaimIdentity: Hashable {
        let runID: UInt64
        let claimGeneration: UInt64
    }

    private let authorityID = UUID()
    private var claimed: Set<ClaimIdentity> = []

    func claim(
        runID: UInt64,
        claimGeneration: UInt64
    ) -> NativeTranslationAppleResultLabHostReceipt? {
        let identity = ClaimIdentity(
            runID: runID,
            claimGeneration: claimGeneration
        )
        guard claimed.insert(identity).inserted else { return nil }
        return NativeTranslationAppleResultLabHostReceiptAuthority.mint(
            authorityID: authorityID,
            runID: runID,
            claimGeneration: claimGeneration
        )
    }
}

enum NativeTranslationAppleResultLabProvenance: Equatable, Sendable {
    case realAppleTranslation
    case unverified
}

/// A live-only bridge envelope. It deliberately carries neither source text
/// nor unstructured failures. Success text is retained only until validation.
struct NativeTranslationAppleResultLabEnvelope: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let fixtureID: NativeTranslationAppleResultLabFixtureID
    let provenance: NativeTranslationAppleResultLabProvenance
    let requestedEngine: NativeTranslationEngine
    let domainGeneration: UInt64
    let presentationLease: NativeTranslationOverlayExternalPresentationLease
    let hostReceipt: NativeTranslationAppleResultLabHostReceipt
    let outcome: NativeTranslationOutcome
    let elapsedMilliseconds: Int
    let inputWasTruncated: Bool

    var description: String {
        "NativeTranslationAppleResultLabEnvelope(fixture: \(fixtureID.rawValue), provenance: [REDACTED], engine: \(requestedEngine.rawValue), generation: \(domainGeneration), outcome: \(outcome.description), lease: [REDACTED], hostReceipt: [REDACTED])"
    }

    var debugDescription: String { description }
}

enum NativeTranslationAppleResultLabPresentationCategory: Equatable {
    case loading
    case success
    case appleNotice
    case appleError
    case safetyFailure
    case timeout
}

/// Only this validated value may cross the real Result Lab → overlay boundary.
struct NativeTranslationAppleResultLabValidatedPresentation: Equatable {
    let overlayState: NativeTranslationOverlayState
    let category: NativeTranslationAppleResultLabPresentationCategory

    private init(
        _ overlayState: NativeTranslationOverlayState,
        category: NativeTranslationAppleResultLabPresentationCategory
    ) {
        self.overlayState = overlayState
        self.category = category
    }

    static func loading(isExtended: Bool) -> Self {
        Self(
            NativeTranslationOverlayState(
                kind: .loading,
                title: "正在运行真实 Apple Translation…",
                body: isExtended
                    ? "仍在等待 Apple Translation；不会改用火山云端。"
                    : "",
                metadata: baseMetadata,
                fallbackNotice: nil,
                truncationBadge: nil,
                truncationAccessibilityHelp: nil,
                copyText: nil,
                cta: nil,
                terminalAnnouncement: nil
            ),
            category: .loading
        )
    }

    static func timeout() -> Self {
        terminal(
            kind: .error,
            title: "Apple Translation 暂时没有响应",
            body: "已停止句译等待；迟到结果不会显示或复制，也不会改用火山云端。",
            metadata: baseMetadata,
            announcement: "句译，Apple Translation 暂时没有响应",
            category: .timeout
        )
    }

    static func safetyFailure() -> Self {
        terminal(
            kind: .error,
            title: "真实 Apple 结果未通过 Debug 安全检查",
            body: "没有显示或保留这次真实 Apple 结果；不会改用火山云端。",
            metadata: baseMetadata,
            announcement: "句译，真实 Apple 结果未通过 Debug 安全检查",
            category: .safetyFailure
        )
    }

    fileprivate static func success(
        text: String,
        elapsedMilliseconds: Int
    ) -> Self {
        Self(
            NativeTranslationOverlayState(
                kind: .success,
                title: "Apple Translation 真实译文",
                body: text,
                metadata: "\(baseMetadata) · 实际耗时 \(elapsedMilliseconds) 毫秒",
                fallbackNotice: nil,
                truncationBadge: nil,
                truncationAccessibilityHelp: nil,
                copyText: text,
                cta: nil,
                terminalAnnouncement: "句译，Debug 固定样例 Apple Translation 完成"
            ),
            category: .success
        )
    }

    static func failure(_ failure: NativeTranslationFailure) -> Self {
        let content: (
            NativeTranslationOverlayState.Kind,
            String,
            String,
            NativeTranslationAppleResultLabPresentationCategory
        )
        switch failure {
        case .appleNeedsPreparation:
            content = (
                .notice,
                "Apple 语言包尚未准备",
                "请返回真实 Apple 结果实验室准备语言包后重试。",
                .appleNotice
            )
        case .appleUnsupported:
            content = (
                .notice,
                "Apple Translation 不支持此语言对",
                "没有改用其他翻译方式。",
                .appleNotice
            )
        case .appleTemporarilyUnavailable:
            content = (
                .error,
                "Apple Translation 暂时不可用",
                "请稍后重试；不会改用火山云端。",
                .appleError
            )
        case .appleExecutionFailed:
            content = (
                .error,
                "Apple Translation 未能完成",
                "没有显示或保留无效结果；不会改用火山云端。",
                .appleError
            )
        default:
            return safetyFailure()
        }
        return terminal(
            kind: content.0,
            title: content.1,
            body: content.2,
            metadata: baseMetadata,
            announcement: "句译，Debug 固定样例，\(content.1)",
            category: content.3
        )
    }

    private static let baseMetadata =
        "Debug 固定样例 · 真实 Apple Translation · 本机处理"

    private static func terminal(
        kind: NativeTranslationOverlayState.Kind,
        title: String,
        body: String,
        metadata: String,
        announcement: String,
        category: NativeTranslationAppleResultLabPresentationCategory
    ) -> Self {
        Self(
            NativeTranslationOverlayState(
                kind: kind,
                title: title,
                body: body,
                metadata: metadata,
                fallbackNotice: nil,
                truncationBadge: nil,
                truncationAccessibilityHelp: nil,
                copyText: nil,
                cta: nil,
                terminalAnnouncement: announcement
            ),
            category: category
        )
    }
}

enum NativeTranslationAppleResultLabPresentationDecision: Equatable {
    case present(NativeTranslationAppleResultLabValidatedPresentation)
    case drop
}

enum NativeTranslationAppleResultLabPresentationBridge {
    private static let maximumResultScalarCount = 20_000
    private static let maximumElapsedMilliseconds = 12_000

    static func map(
        _ envelope: NativeTranslationAppleResultLabEnvelope,
        expectedDomainGeneration: UInt64,
        expectedLease: NativeTranslationOverlayExternalPresentationLease,
        expectedHostReceipt: NativeTranslationAppleResultLabHostReceipt
    ) -> NativeTranslationAppleResultLabPresentationDecision {
        guard envelope.domainGeneration == expectedDomainGeneration,
              envelope.presentationLease == expectedLease,
              envelope.hostReceipt == expectedHostReceipt else {
            return .drop
        }

        if case .cancelled = envelope.outcome {
            return .drop
        }

        guard envelope.fixtureID == .appleFixedSample,
              envelope.provenance == .realAppleTranslation,
              envelope.requestedEngine == .apple,
              (0...maximumElapsedMilliseconds).contains(
                  envelope.elapsedMilliseconds
              ),
              envelope.inputWasTruncated == false else {
            return .present(.safetyFailure())
        }

        switch envelope.outcome {
        case let .success(success):
            guard success.engine == .apple,
                  success.inputWasTruncated == false,
                  resultIsSafe(success.text) else {
                return .present(.safetyFailure())
            }
            return .present(
                .success(
                    text: success.text,
                    elapsedMilliseconds: envelope.elapsedMilliseconds
                )
            )

        case let .failure(failure):
            guard failureIsAppleTyped(failure) else {
                return .present(.safetyFailure())
            }
            return .present(.failure(failure))

        case .skipped(.tooShort):
            return .present(.safetyFailure())

        case .cancelled:
            return .drop
        }
    }

    private static func failureIsAppleTyped(
        _ failure: NativeTranslationFailure
    ) -> Bool {
        switch failure {
        case .appleNeedsPreparation, .appleUnsupported,
             .appleTemporarilyUnavailable, .appleExecutionFailed:
            return true
        default:
            return false
        }
    }

    private static func resultIsSafe(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard scalars.count <= maximumResultScalarCount,
              scalars.contains(where: { !$0.properties.isWhitespace }) else {
            return false
        }
        return scalars.allSatisfy { scalar in
            scalar == "\n"
                || scalar == "\t"
                || scalar.properties.generalCategory != .control
        }
    }
}
#endif
