#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
import Foundation

public let nativeVolcTranslationAdapterBuildSentinel =
    "juyi-native-volc-translation-adapter-v1"

enum NativeVolcDebugFixture {
    static let sourceText = "Good tools should feel effortless."
    static let sourceLanguage = "en"
    static let targetLanguage = "zh"
    static let exactEndpoint =
        "https://translate.volcengineapi.com/?Action=TranslateText&Version=2020-06-01"
}

enum NativeVolcTransportFailure: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    case network
    case transportSecurity
    case timeout
    case cancelled

    var description: String {
        switch self {
        case .network: return "network"
        case .transportSecurity: return "transport_security"
        case .timeout: return "timeout"
        case .cancelled: return "cancelled"
        }
    }

    var debugDescription: String { description }
}

enum NativeVolcTransportResult: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    case response(statusCode: Int, data: Data)
    case failure(NativeVolcTransportFailure)

    var description: String {
        switch self {
        case let .response(statusCode, data):
            return "response(status: \(statusCode), bytes: \(data.count), body: [REDACTED])"
        case let .failure(failure): return "failure(\(failure.description))"
        }
    }

    var debugDescription: String { description }
}

protocol NativeVolcTransportLease: AnyObject, Sendable {
    func releaseGate()
    func releaseTransport()
}

extension NativeVolcReaderLease: NativeVolcTransportLease {}

struct NativeVolcTransportConfigurationFactory: @unchecked Sendable {
    let make: @Sendable () -> URLSessionConfiguration
    let beforeDelegateStart: @Sendable () async -> Void

    init(
        make: @escaping @Sendable () -> URLSessionConfiguration,
        beforeDelegateStart: @escaping @Sendable () async -> Void = {}
    ) {
        self.make = make
        self.beforeDelegateStart = beforeDelegateStart
    }

    static let live = NativeVolcTransportConfigurationFactory(make: {
        URLSessionConfiguration.ephemeral
    })
}

final class NativeVolcDebugTransport: @unchecked Sendable {
    private let configurationFactory: NativeVolcTransportConfigurationFactory

    init(configurationFactory: NativeVolcTransportConfigurationFactory = .live) {
        self.configurationFactory = configurationFactory
    }

    func execute(
        _ signed: VolcV4SignedRequest,
        lease: any NativeVolcTransportLease
    ) async -> NativeVolcTransportResult {
        if Task.isCancelled {
            lease.releaseGate()
            lease.releaseTransport()
            return .failure(.cancelled)
        }
        guard let request = Self.makeRequest(signed) else {
            lease.releaseGate()
            lease.releaseTransport()
            return .failure(.transportSecurity)
        }
        let configuration = configurationFactory.make()
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10

        let delegate = NativeVolcStreamingSessionDelegate(
            expectedURL: request.url!,
            lease: lease
        )
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.attach(session: session)
        let task = session.dataTask(with: request)
        return await withTaskCancellationHandler {
            await configurationFactory.beforeDelegateStart()
            return await delegate.start(task)
        } onCancel: {
            delegate.cancel()
        }
    }

    static func makeRequest(_ signed: VolcV4SignedRequest) -> URLRequest? {
        let expectedBody = try? VolcV4RequestBuilder.deterministicBody(
            text: NativeVolcDebugFixture.sourceText,
            sourceLanguage: NativeVolcDebugFixture.sourceLanguage,
            targetLanguage: NativeVolcDebugFixture.targetLanguage
        )
        let requiredHeaders: Set<String> = [
            "Content-Type", "Host", "X-Date", "X-Content-Sha256", "Authorization",
        ]
        guard signed.method == "POST",
              signed.scheme == "https",
              signed.host == "translate.volcengineapi.com",
              signed.canonicalURI == "/",
              signed.canonicalQuery == "Action=TranslateText&Version=2020-06-01",
              signed.endpoint == NativeVolcDebugFixture.exactEndpoint,
              signed.body == expectedBody,
              Set(signed.headers.keys) == requiredHeaders,
              signed.headers["Content-Type"] == "application/json; charset=utf-8",
              signed.headers["Host"] == "translate.volcengineapi.com",
              signed.headers["X-Content-Sha256"]
                == VolcV4RequestBuilder.sha256Hex(signed.body),
              let xDate = signed.headers["X-Date"], validXDate(xDate),
              let authorization = signed.headers["Authorization"],
              validAuthorization(authorization, xDate: xDate),
              let url = URL(string: signed.endpoint),
              url.absoluteString == NativeVolcDebugFixture.exactEndpoint
        else { return nil }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.httpMethod = "POST"
        request.httpBody = signed.body
        for (name, value) in signed.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpShouldHandleCookies = false
        return request
    }

    static func validXDate(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 16, bytes[8] == 0x54, bytes[15] == 0x5A else { return false }
        return bytes.enumerated().allSatisfy { index, byte in
            index == 8 || index == 15 || (0x30...0x39).contains(byte)
        }
    }

    static func validAuthorization(_ value: String, xDate: String) -> Bool {
        guard validXDate(xDate) else { return false }
        let prefix = "HMAC-SHA256 Credential="
        let separator = "/\(xDate.prefix(8))/cn-north-1/translate/request, "
            + "SignedHeaders=content-type;host;x-content-sha256;x-date, Signature="
        guard value.hasPrefix(prefix),
              let range = value.range(of: separator),
              range.lowerBound > value.index(value.startIndex, offsetBy: prefix.count)
        else { return false }
        let accessKey = value[value.index(value.startIndex, offsetBy: prefix.count)..<range.lowerBound]
        let signature = value[range.upperBound...]
        guard (1...256).contains(accessKey.utf8.count), signature.utf8.count == 64 else {
            return false
        }
        let accessKeyIsValid = accessKey.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
                || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x2E || byte == 0x5F
        }
        let signatureIsValid = signature.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
        return accessKeyIsValid && signatureIsValid
    }
}

struct NativeVolcDebugTransportClient: Sendable {
    let execute: @Sendable (
        VolcV4SignedRequest, any NativeVolcTransportLease
    ) async -> NativeVolcTransportResult

    static let live = NativeVolcDebugTransportClient { request, lease in
        await NativeVolcDebugTransport().execute(request, lease: lease)
    }
}

enum NativeVolcTransportChallengePolicy {
    static func allowsDefaultServerTrust(
        authenticationMethod: String,
        host: String,
        protocolName: String?,
        port: Int,
        hasServerTrust: Bool
    ) -> Bool {
        authenticationMethod == NSURLAuthenticationMethodServerTrust
            && host == "translate.volcengineapi.com"
            && protocolName?.lowercased() == "https"
            && port == 443
            && hasServerTrust
    }
}

private final class NativeVolcStreamingSessionDelegate: NSObject, @unchecked Sendable,
    URLSessionDataDelegate, URLSessionTaskDelegate
{
    private struct State {
        var task: URLSessionDataTask?
        weak var session: URLSession?
        var continuation: CheckedContinuation<NativeVolcTransportResult, Never>?
        var response: HTTPURLResponse?
        var data = Data()
        var forcedFailure: NativeVolcTransportFailure?
        var cancelRequested = false
        var completed = false
    }

    private let lock = NSLock()
    private let expectedURL: URL
    private let lease: any NativeVolcTransportLease
    private var state = State()

    init(expectedURL: URL, lease: any NativeVolcTransportLease) {
        self.expectedURL = expectedURL
        self.lease = lease
    }

    func attach(session: URLSession) {
        lock.withLock { state.session = session }
    }

    func start(_ task: URLSessionDataTask) async -> NativeVolcTransportResult {
        await withCheckedContinuation { continuation in
            enum StartDecision { case rejected, cancelled, resumed }
            let decision = lock.withLock { () -> StartDecision in
                guard !state.completed, state.continuation == nil else {
                    return .rejected
                }
                state.continuation = continuation
                state.task = task
                guard !state.cancelRequested else { return .cancelled }
                // The cancellation check and resume commitment share one lock.
                // A concurrent cancel therefore linearizes either before resume
                // (zero request) or after the task has legitimately started.
                task.resume()
                return .resumed
            }
            switch decision {
            case .rejected:
                continuation.resume(returning: .failure(.cancelled))
            case .cancelled:
                task.cancel()
                lease.releaseGate()
                finish(.failure(.cancelled))
            case .resumed:
                lease.releaseGate()
            }
        }
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionDataTask? in
            state.cancelRequested = true
            return state.task
        }
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              response.url?.absoluteString == expectedURL.absoluteString
        else {
            setForcedFailure(.transportSecurity)
            completionHandler(.cancel)
            dataTask.cancel()
            return
        }
        if http.statusCode >= 300 && http.statusCode <= 399 {
            setForcedFailure(.transportSecurity)
            completionHandler(.cancel)
            dataTask.cancel()
            return
        }
        let declared = response.expectedContentLength
        if declared > Int64(VolcTranslationResponseParser.maximumPayloadBytes) {
            setForcedFailure(.transportSecurity)
            completionHandler(.cancel)
            dataTask.cancel()
            return
        }
        lock.withLock { state.response = http }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let overflow = lock.withLock { () -> Bool in
            guard state.forcedFailure == nil else { return true }
            let remaining = VolcTranslationResponseParser.maximumPayloadBytes - state.data.count
            guard data.count <= remaining else {
                state.forcedFailure = .transportSecurity
                state.data.removeAll(keepingCapacity: false)
                return true
            }
            state.data.append(data)
            return false
        }
        if overflow { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if allowsDefaultHandling(challenge.protectionSpace) {
            completionHandler(.performDefaultHandling, nil)
        } else {
            rejectAuthentication(completionHandler)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        setForcedFailure(.transportSecurity)
        completionHandler(nil)
        task.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if allowsDefaultHandling(challenge.protectionSpace) {
            completionHandler(.performDefaultHandling, nil)
        } else {
            setForcedFailure(.transportSecurity)
            completionHandler(.cancelAuthenticationChallenge, nil)
            task.cancel()
        }
    }

    private func allowsDefaultHandling(_ protection: URLProtectionSpace) -> Bool {
        NativeVolcTransportChallengePolicy.allowsDefaultServerTrust(
            authenticationMethod: protection.authenticationMethod,
            host: protection.host,
            protocolName: protection.protocol,
            port: protection.port,
            hasServerTrust: protection.serverTrust != nil
        )
    }

    private func rejectAuthentication(
        _ completionHandler: @escaping (
            URLSession.AuthChallengeDisposition, URLCredential?
        ) -> Void
    ) {
        setForcedFailure(.transportSecurity)
        completionHandler(.cancelAuthenticationChallenge, nil)
        let task = lock.withLock { state.task }
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let result = lock.withLock { () -> NativeVolcTransportResult in
            if let forced = state.forcedFailure { return .failure(forced) }
            if let error = error as? URLError {
                return .failure(Self.classify(error))
            }
            guard error == nil, let response = state.response else {
                return .failure(.transportSecurity)
            }
            return .response(statusCode: response.statusCode, data: state.data)
        }
        finish(result)
    }

    private func setForcedFailure(_ failure: NativeVolcTransportFailure) {
        lock.withLock {
            if state.forcedFailure == nil { state.forcedFailure = failure }
        }
    }

    private func finish(_ result: NativeVolcTransportResult) {
        let completion = lock.withLock { () -> (
            Bool, CheckedContinuation<NativeVolcTransportResult, Never>?, URLSession?
        ) in
            guard !state.completed else { return (false, nil, nil) }
            state.completed = true
            let continuation = state.continuation
            let session = state.session
            state.continuation = nil
            state.task = nil
            state.session = nil
            state.response = nil
            state.data.removeAll(keepingCapacity: false)
            return (true, continuation, session)
        }
        guard completion.0 else { return }
        lease.releaseTransport()
        completion.2?.finishTasksAndInvalidate()
        completion.1?.resume(returning: result)
    }

    private static func classify(_ error: URLError) -> NativeVolcTransportFailure {
        switch error.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timeout
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return .transportSecurity
        default:
            return .network
        }
    }
}
#endif
