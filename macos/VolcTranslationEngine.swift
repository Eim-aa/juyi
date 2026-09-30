import Foundation

enum VolcTranslationOutcome: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    case translated(String)
    case failed(VolcTranslationError)
    case cancelled

    var description: String {
        switch self {
        case .translated: return "translated([REDACTED])"
        case let .failed(error): return "failed(\(error.description))"
        case .cancelled: return "cancelled"
        }
    }

    var debugDescription: String { description }
}

extension VolcTranslationError {
    /// The overlay's existing cloud copy; credential problems carry the
    /// `checkCloudSettings` call to action there.
    var overlayError: NativeTranslationOverlayBackendError {
        switch self {
        case .credential: return .volcCredential
        case .network: return .volcNetwork
        case .timeout: return .volcTimeout
        case .httpFailure: return .httpFailure
        case .malformedResponse: return .malformedResponse
        case .emptyResult: return .emptyResult
        }
    }
}

/// Native English → Simplified Chinese client for Volcengine TranslateText.
///
/// Privacy boundary: credentials come from an injected provider (the Keychain
/// via `/usr/bin/security`, read off the main actor) and live only in memory.
/// They are cached after a successful read and dropped by `forgetCredentials`.
/// Nothing here logs, prints, or persists; the request carries only the signed
/// `Authorization` header, never the secret key.
@MainActor
final class VolcTranslationEngine {
    typealias CredentialProvider = @Sendable () async -> VolcV4Credentials?

    static let shared = VolcTranslationEngine()
    /// Matches the coordinator's translation deadline.
    nonisolated static let requestTimeout: TimeInterval = 12
    nonisolated static let validationText = "Good tools should feel effortless."
    nonisolated static let sourceLanguage = "en"
    nonisolated static let targetLanguage = "zh"

    var credentialProvider: CredentialProvider

    private let session: URLSession
    private let now: @Sendable () -> Date
    private let redirectRefusal = VolcRedirectRefusal()
    private var cachedCredentials: VolcV4Credentials?
    private var credentialEpoch: UInt64 = 0
    private var requestGeneration: UInt64 = 0
    private var currentRequest: VolcRequestHandle?

    init(
        session: URLSession = VolcTranslationEngine.makeSession(),
        credentialProvider: @escaping CredentialProvider = { nil },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.credentialProvider = credentialProvider
        self.now = now
    }

    /// Ephemeral, cookie-free and cache-free; fails fast without connectivity.
    nonisolated static func makeSession(
        configuration: URLSessionConfiguration = .ephemeral
    ) -> URLSession {
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }

    /// Translates the current selection. Starting a request cancels the
    /// previous one; `cancelCurrent()` cancels the in-flight URLSession task.
    func translate(_ text: String) async -> VolcTranslationOutcome {
        cancelCurrent()
        requestGeneration &+= 1
        let generation = requestGeneration
        guard let credentials = await loadCredentials() else {
            return .failed(.credential)
        }
        guard generation == requestGeneration, !Task.isCancelled else { return .cancelled }
        let handle = VolcRequestHandle()
        currentRequest = handle
        let outcome = await perform(text: text, credentials: credentials, handle: handle)
        if currentRequest === handle { currentRequest = nil }
        if outcome == .failed(.credential) { forgetCredentials() }
        return outcome
    }

    /// Validates a candidate credential with one fixed English sentence. The
    /// candidate is neither cached nor stored, and a translation in flight is
    /// not affected.
    func validate(credentials: VolcV4Credentials) async -> VolcTranslationOutcome {
        await perform(
            text: Self.validationText,
            credentials: credentials,
            handle: VolcRequestHandle()
        )
    }

    /// Diagnostics: validates the stored credential without touching the
    /// selection translation in flight.
    func validateStoredCredentials() async -> VolcTranslationOutcome {
        guard let credentials = await loadCredentials() else { return .failed(.credential) }
        let outcome = await validate(credentials: credentials)
        if outcome == .failed(.credential) { forgetCredentials() }
        return outcome
    }

    /// Reads (and caches) the stored credential without sending anything.
    func hasCredentials() async -> Bool {
        await loadCredentials() != nil
    }

    func cancelCurrent() {
        requestGeneration &+= 1
        currentRequest?.cancel()
        currentRequest = nil
    }

    /// Drops the in-memory copy (credential removed, replaced, or the Apple
    /// engine selected). A read already in flight cannot repopulate it.
    func forgetCredentials() {
        credentialEpoch &+= 1
        cachedCredentials = nil
    }

    private func loadCredentials() async -> VolcV4Credentials? {
        if let cachedCredentials { return cachedCredentials }
        let epoch = credentialEpoch
        guard let credentials = await credentialProvider() else { return nil }
        if epoch == credentialEpoch { cachedCredentials = credentials }
        return credentials
    }

    private func perform(
        text: String,
        credentials: VolcV4Credentials,
        handle: VolcRequestHandle
    ) async -> VolcTranslationOutcome {
        let signed: VolcV4SignedRequest
        do {
            signed = try VolcV4RequestBuilder.build(
                credentials: credentials,
                text: text,
                source: Self.sourceLanguage,
                target: Self.targetLanguage,
                now: now()
            )
        } catch VolcV4RequestBuilderError.invalidCredentials {
            return .failed(.credential)
        } catch {
            return .failed(.httpFailure)
        }

        var request = URLRequest(
            url: signed.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.requestTimeout
        )
        request.httpMethod = signed.method
        request.httpBody = signed.body
        request.httpShouldHandleCookies = false
        for (name, value) in signed.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let signedRequest = request
        let session = session
        let redirectRefusal = redirectRefusal
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let task = session.dataTask(with: signedRequest) { data, response, error in
                    continuation.resume(
                        returning: Self.outcome(data: data, response: response, error: error)
                    )
                }
                task.delegate = redirectRefusal
                handle.start(task)
            }
        } onCancel: {
            handle.cancel()
        }
    }

    nonisolated static func outcome(
        data: Data?,
        response: URLResponse?,
        error: (any Error)?
    ) -> VolcTranslationOutcome {
        if let error {
            guard let urlError = error as? URLError else { return .failed(.network) }
            switch urlError.code {
            case .cancelled: return .cancelled
            case .timedOut: return .failed(.timeout)
            default: return .failed(.network)
            }
        }
        guard let http = response as? HTTPURLResponse else {
            return .failed(.malformedResponse)
        }
        switch VolcTranslationResponseParser.parse(
            statusCode: http.statusCode,
            data: data ?? Data()
        ) {
        case let .success(translation): return .translated(translation)
        case let .failure(error): return .failed(error)
        }
    }
}

/// Cancellation handle shared between the engine, the Swift task
/// cancellation handler, and the URLSession callback queue.
private final class VolcRequestHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func start(_ task: URLSessionTask) {
        let alreadyCancelled = lock.withLock { () -> Bool in
            self.task = task
            return cancelled
        }
        if alreadyCancelled { task.cancel() } else { task.resume() }
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionTask? in
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}

/// A redirect could forward the signed request elsewhere. Refuse it; the
/// 3xx response is then reported as an HTTP failure.
private final class VolcRedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
