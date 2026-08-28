#if DEBUG && JUYI_NATIVE_TRANSLATION_RESULT_LAB && (JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER || JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER)
#error("Result Lab cannot be compiled with a live native translation adapter")
#endif

#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
import Foundation

public let nativeTranslationResultLabBuildSentinel =
    "juyi-native-translation-result-lab-v1"

enum NativeTranslationResultLabFixtureID: String, Equatable, Sendable {
    case appleFixedSample
    case volcFixedSample
    case unrecognized

    var expectedEngine: NativeTranslationEngine? {
        switch self {
        case .appleFixedSample: return .apple
        case .volcFixedSample: return .volc
        case .unrecognized: return nil
        }
    }
}

enum NativeTranslationResultLabProvenance: Equatable, Sendable {
    case simulated
}

/// The bridge envelope deliberately contains no source text, credentials,
/// fingerprint, request bytes, HTTP fields or raw Error.
struct NativeTranslationResultLabEnvelope: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let fixtureID: NativeTranslationResultLabFixtureID
    let provenance: NativeTranslationResultLabProvenance
    let requestedEngine: NativeTranslationEngine
    let domainGeneration: UInt64
    let presentationLease: NativeTranslationOverlayExternalPresentationLease
    let outcome: NativeTranslationOutcome
    let simulatedElapsedMilliseconds: Int
    let inputWasTruncated: Bool

    var description: String {
        "NativeTranslationResultLabEnvelope(fixture: \(fixtureID.rawValue), provenance: simulated, engine: \(requestedEngine.rawValue), generation: \(domainGeneration), outcome: \(outcome.description), lease: [REDACTED])"
    }

    var debugDescription: String { description }
}

/// Only this type can cross the Result Lab → overlay session boundary. Its
/// initializer is private; every terminal instance has passed the strict bridge.
enum NativeTranslationResultLabPresentationCategory: Equatable {
    case loading
    case success
    case simulatedNotice
    case simulatedError
    case safetyFailure
    case timeout
}

struct NativeTranslationResultLabValidatedPresentation: Equatable {
    let overlayState: NativeTranslationOverlayState
    let category: NativeTranslationResultLabPresentationCategory

    private init(
        _ overlayState: NativeTranslationOverlayState,
        category: NativeTranslationResultLabPresentationCategory
    ) {
        self.overlayState = overlayState
        self.category = category
    }

    static func loading(
        engine: NativeTranslationEngine,
        isExtended: Bool
    ) -> Self {
        let title = engine == .apple
            ? "正在运行 Apple Debug 模拟…"
            : "正在运行火山 Debug 模拟…"
        let boundary = engine == .apple
            ? "未调用 Apple Translation"
            : "未读密钥、未联网、不计费"
        return Self(
            NativeTranslationOverlayState(
                kind: .loading,
                title: title,
                body: isExtended ? "模拟仍在进行；\(boundary)。" : "",
                metadata: "Debug 固定样例 · 模拟执行 · \(boundary)",
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

    static func timeout(engine: NativeTranslationEngine) -> Self {
        return terminal(
            kind: .error,
            title: "模拟执行超时",
            body: "已停止模拟；迟到结果不会显示或复制。未调用真实翻译服务。",
            metadata: metadata(engine: engine, elapsed: nil),
            announcement: "句译，Debug 固定样例模拟已超时",
            category: .timeout
        )
    }

    static func safetyFailure(engine: NativeTranslationEngine) -> Self {
        let liveBoundary = engine == .apple
            ? "未调用 Apple Translation。"
            : "未读密钥、未联网、不计费。"
        return terminal(
            kind: .error,
            title: "结果未通过 Debug 安全检查",
            body: "没有显示或保留这次模拟结果。\(liveBoundary)请返回 Result Lab 后重试。",
            metadata: metadata(engine: engine, elapsed: nil),
            announcement: "句译，Debug 固定样例结果未通过安全检查",
            category: .safetyFailure
        )
    }

    fileprivate static func success(
        engine: NativeTranslationEngine,
        text: String,
        elapsed: Int,
        inputWasTruncated: Bool
    ) -> Self {
        Self(
            NativeTranslationOverlayState(
                kind: .success,
                title: engine == .apple ? "Apple 模拟译文" : "火山模拟译文",
                body: text,
                metadata: metadata(engine: engine, elapsed: elapsed),
                fallbackNotice: nil,
                truncationBadge: inputWasTruncated ? "原文已截断" : nil,
                truncationAccessibilityHelp: inputWasTruncated
                    ? "仅翻译固定原文前 5000 个 Unicode 标量"
                    : nil,
                copyText: text,
                cta: nil,
                terminalAnnouncement: engine == .apple
                    ? "句译，Debug 固定样例 Apple 模拟完成"
                    : "句译，Debug 固定样例火山模拟完成"
            ),
            category: .success
        )
    }

    fileprivate static func failure(
        _ failure: NativeTranslationFailure,
        engine: NativeTranslationEngine
    ) -> Self {
        let content: (NativeTranslationOverlayState.Kind, String, String)
        switch failure {
        case .emptyInput:
            content = (.error, "固定样例为空", "没有运行模拟，也没有调用真实翻译服务。")
        case .sourceLanguageMismatch:
            content = (.notice, "固定样例不像英文", "没有运行模拟，也没有调用真实翻译服务。")
        case .appleNeedsPreparation:
            content = (.notice, "Apple 模拟语言包尚未准备", "这是固定 Debug 状态；未调用 Apple Translation。")
        case .appleUnsupported:
            content = (.notice, "Apple 模拟在此环境不可用", "没有改用其他引擎。")
        case .appleTemporarilyUnavailable:
            content = (.error, "Apple 模拟暂时不可用", "请返回 Result Lab 后重试；没有改用云端。")
        case .appleExecutionFailed:
            content = (.error, "Apple 模拟未能完成", "未调用 Apple Translation；没有显示任何错误原文。")
        case .cloudConsentRequired:
            content = (.notice, "模拟云端授权未通过", "未读密钥、未联网、不计费。")
        case .cloudRemovalPresent:
            content = (.notice, "模拟移除状态阻止了请求", "未读密钥、未联网、不计费。")
        case .cloudRemovalStateUnavailable:
            content = (.error, "无法确认模拟云端安全状态", "未读密钥、未联网、不计费。")
        case .cloudCredentialsMissing:
            content = (.notice, "模拟云端密钥缺失", "只检查内存 fixture；未读钥匙串。")
        case .cloudCredentialsPending:
            content = (.notice, "模拟云端密钥仍待验证", "未读钥匙串、未联网、不计费。")
        case .cloudCredentialUnverified:
            content = (.error, "模拟云端密钥未验证", "未读钥匙串、未联网、不计费。")
        case .cloudCredentialSnapshotMismatch:
            content = (.error, "模拟云端密钥快照不一致", "已停止模拟；未联网、不计费。")
        case .volcCredential:
            content = (.error, "火山模拟凭据错误", "未读真实密钥，也没有发送请求。")
        case .volcNetwork:
            content = (.error, "火山模拟网络错误", "这是内存中的固定错误；没有联网。")
        case .volcTransportSecurity:
            content = (.error, "火山模拟安全连接错误", "这是内存中的固定错误；没有联网。")
        case .volcTimeout:
            content = (.error, "火山模拟超时", "已停止模拟；迟到结果不会显示或复制。")
        case .volcQuota:
            content = (.error, "火山模拟额度受限", "这是固定 Debug 状态；不产生费用。")
        case .volcService, .volcHTTP:
            content = (.error, "火山模拟服务错误", "没有显示上游正文、状态码或错误消息。")
        case .volcMalformedResponse:
            content = (.error, "火山模拟没有有效译文", "没有显示或保留无效响应。")
        }
        return terminal(
            kind: content.0,
            title: content.1,
            body: content.2,
            metadata: metadata(engine: engine, elapsed: nil),
            announcement: "句译，Debug 固定样例，\(content.1)",
            category: content.0 == .notice ? .simulatedNotice : .simulatedError
        )
    }

    private static func terminal(
        kind: NativeTranslationOverlayState.Kind,
        title: String,
        body: String,
        metadata: String,
        announcement: String,
        category: NativeTranslationResultLabPresentationCategory
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

    private static func metadata(
        engine: NativeTranslationEngine,
        elapsed: Int?
    ) -> String {
        let engineLabel = engine == .apple ? "Apple 离线（模拟）" : "火山云端（模拟）"
        let liveBoundary = engine == .apple
            ? "未调用 Apple Translation"
            : "未读密钥、未联网、不计费"
        guard let elapsed else {
            return "Debug 固定样例 · \(engineLabel) · \(liveBoundary)"
        }
        return "Debug 固定样例 · \(engineLabel) · \(liveBoundary) · 模拟耗时 \(elapsed) 毫秒"
    }
}

enum NativeTranslationResultLabPresentationDecision: Equatable {
    case present(NativeTranslationResultLabValidatedPresentation)
    case dismiss
    case drop
}

enum NativeTranslationResultLabPresentationBridge {
    private static let maximumResultScalarCount = 20_000

    static func map(
        _ envelope: NativeTranslationResultLabEnvelope,
        expectedDomainGeneration: UInt64,
        expectedLease: NativeTranslationOverlayExternalPresentationLease
    ) -> NativeTranslationResultLabPresentationDecision {
        guard envelope.domainGeneration == expectedDomainGeneration,
              envelope.presentationLease == expectedLease else {
            return .drop
        }
        let fixture = envelope.fixtureID
        guard envelope.provenance == .simulated,
              envelope.simulatedElapsedMilliseconds >= 0,
              fixture.expectedEngine == envelope.requestedEngine else {
            return .present(.safetyFailure(engine: envelope.requestedEngine))
        }

        switch envelope.outcome {
        case .cancelled:
            return .dismiss
        case .skipped(.tooShort):
            return .present(.safetyFailure(engine: envelope.requestedEngine))

        case let .success(success):
            guard envelope.requestedEngine == success.engine,
                  envelope.inputWasTruncated == false,
                  success.inputWasTruncated == false,
                  success.inputWasTruncated == envelope.inputWasTruncated,
                  success.text == expectedResult(for: fixture),
                  success.text.unicodeScalars.count <= maximumResultScalarCount,
                  resultContainsForbiddenScalar(success.text) == false else {
                return .present(.safetyFailure(engine: envelope.requestedEngine))
            }
            return .present(
                .success(
                    engine: success.engine,
                    text: success.text,
                    elapsed: envelope.simulatedElapsedMilliseconds,
                    inputWasTruncated: envelope.inputWasTruncated
                )
            )

        case .failure(.emptyInput), .failure(.sourceLanguageMismatch):
            return .present(.safetyFailure(engine: envelope.requestedEngine))

        case let .failure(failure):
            guard failureIsCompatible(
                failure,
                requestedEngine: envelope.requestedEngine
            ) else {
                return .present(.safetyFailure(engine: envelope.requestedEngine))
            }
            return .present(.failure(failure, engine: envelope.requestedEngine))
        }
    }

    private static func expectedResult(
        for fixture: NativeTranslationResultLabFixtureID
    ) -> String? {
        switch fixture {
        case .appleFixedSample: return NativeTranslationResultLabFixtures.appleResult
        case .volcFixedSample: return NativeTranslationResultLabFixtures.volcResult
        case .unrecognized: return nil
        }
    }

    private static func isAllowedResultScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\t" { return true }
        let value = scalar.value
        return value >= 0x20 && value != 0x7F
    }

    private static func resultContainsForbiddenScalar(_ text: String) -> Bool {
        !text.unicodeScalars.allSatisfy(isAllowedResultScalar)
    }

    private static func failureIsCompatible(
        _ failure: NativeTranslationFailure,
        requestedEngine: NativeTranslationEngine
    ) -> Bool {
        switch failure {
        case .emptyInput, .sourceLanguageMismatch:
            return true
        case .appleNeedsPreparation, .appleUnsupported,
             .appleTemporarilyUnavailable, .appleExecutionFailed:
            return requestedEngine == .apple
        case .cloudConsentRequired, .cloudRemovalPresent,
             .cloudRemovalStateUnavailable, .cloudCredentialsMissing,
             .cloudCredentialsPending, .cloudCredentialUnverified,
             .cloudCredentialSnapshotMismatch, .volcCredential, .volcNetwork,
             .volcTransportSecurity, .volcTimeout, .volcQuota, .volcService,
             .volcHTTP, .volcMalformedResponse:
            return requestedEngine == .volc
        }
    }
}
#endif
