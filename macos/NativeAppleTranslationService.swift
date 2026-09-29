import AppKit
import SwiftUI
import Translation

// MARK: - Production Apple Translation host

enum NativeAppleProductionReadiness: Equatable, Sendable {
    case installed
    case needsPreparation
    case unsupported
    case unavailable
}

enum NativeAppleProductionResult: Equatable, Sendable {
    case prepared
    case translated(String)
    case needsPreparation
    case unsupported
    case failed
    case cancelled
}

@MainActor
final class NativeAppleProductionTranslationService: ObservableObject {
    enum Intent: Equatable, Sendable {
        case prepare
        case translate(String)
    }

    struct Request: Identifiable, Equatable, Sendable,
        CustomStringConvertible, CustomDebugStringConvertible
    {
        let id: UUID
        let generation: UInt64
        let intent: Intent

        var description: String {
            "NativeAppleProductionRequest(generation: \(generation), payload: [REDACTED])"
        }

        var debugDescription: String { description }
    }

    struct Claim: Equatable, Sendable {
        let request: Request
    }

    static let shared = NativeAppleProductionTranslationService()

    @Published private(set) var request: Request?

    private var generation: UInt64 = 0
    private var claimed = false
    private var continuation: CheckedContinuation<NativeAppleProductionResult, Never>?

    private static let sourceLanguage = Locale.Language(identifier: "en")
    private static let targetLanguage = Locale.Language(identifier: "zh-Hans")

    func readiness() async -> NativeAppleProductionReadiness {
        let status = await LanguageAvailability().status(
            from: Self.sourceLanguage,
            to: Self.targetLanguage
        )
        switch status {
        case .installed: return .installed
        case .supported: return .needsPreparation
        case .unsupported: return .unsupported
        @unknown default: return .unavailable
        }
    }

    func prepareLanguages() async -> NativeAppleProductionResult {
        await begin(.prepare)
    }

    func translate(_ sourceText: String) async -> NativeAppleProductionResult {
        guard !sourceText.isEmpty else { return .failed }
        return await begin(.translate(sourceText))
    }

    func claim(_ candidate: Request) -> Claim? {
        guard request == candidate, !claimed else { return nil }
        claimed = true
        return Claim(request: candidate)
    }

    func complete(
        _ result: NativeAppleProductionResult,
        request candidate: Request
    ) {
        guard request == candidate, claimed else { return }
        finish(result)
    }

    func hostDisappeared(_ candidate: Request) {
        guard request == candidate else { return }
        finish(.cancelled)
    }

    func cancelCurrent() {
        guard request != nil || continuation != nil else { return }
        generation &+= 1
        finish(.cancelled)
    }

    private func begin(_ intent: Intent) async -> NativeAppleProductionResult {
        cancelCurrent()
        generation &+= 1
        let candidate = Request(
            id: UUID(),
            generation: generation,
            intent: intent
        )
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            claimed = false
            request = candidate
        }
    }

    private func finish(_ result: NativeAppleProductionResult) {
        let pending = continuation
        continuation = nil
        request = nil
        claimed = false
        pending?.resume(returning: result)
    }
}

struct NativeAppleProductionTranslationHost: View {
    @ObservedObject var service: NativeAppleProductionTranslationService

    var body: some View {
        Group {
            if let request = service.request {
                NativeAppleProductionTranslationSlot(
                    request: request,
                    service: service
                )
                .id(request.id)
            }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

private struct NativeAppleProductionTranslationSlot: View {
    let request: NativeAppleProductionTranslationService.Request
    @ObservedObject var service: NativeAppleProductionTranslationService
    @State private var configuration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "zh-Hans")
    )

    private static let sourceLanguage = Locale.Language(identifier: "en")
    private static let targetLanguage = Locale.Language(identifier: "zh-Hans")

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { [request] session in
                guard let claim = service.claim(request) else { return }
                let result: NativeAppleProductionResult
                switch claim.request.intent {
                case .prepare:
                    do {
                        try await session.prepareTranslation()
                        result = .prepared
                    } catch {
                        result = Self.classify(error)
                    }

                case let .translate(sourceText):
                    do {
                        let response = try await session.translate(sourceText)
                        guard response.sourceText == sourceText,
                              response.sourceLanguage.languageCode?.identifier == "en",
                              response.targetLanguage.languageCode?.identifier == "zh",
                              !response.targetText.unicodeScalars.allSatisfy({
                                  $0.properties.isWhitespace
                              }) else {
                            service.complete(.failed, request: request)
                            return
                        }
                        result = .translated(response.targetText)
                    } catch {
                        result = Self.classify(error)
                    }
                }
                service.complete(result, request: request)
            }
            .onDisappear {
                service.hostDisappeared(request)
                configuration.invalidate()
            }
    }

    private static func classify(_ error: any Error) -> NativeAppleProductionResult {
        switch error {
        case TranslationError.unsupportedSourceLanguage,
             TranslationError.unsupportedTargetLanguage,
             TranslationError.unsupportedLanguagePairing:
            return .unsupported
        default:
            return .failed
        }
    }
}
