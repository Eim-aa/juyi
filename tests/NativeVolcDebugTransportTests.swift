#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
import Foundation

private final class NativeVolcFakeTransportLease: NativeVolcTransportLease,
    @unchecked Sendable
{
    private let lock = NSLock()
    private(set) var gateReleases = 0
    private(set) var transportReleases = 0

    func releaseGate() { lock.withLock { gateReleases += 1 } }
    func releaseTransport() { lock.withLock { transportReleases += 1 } }
    var counts: (Int, Int) { lock.withLock { (gateReleases, transportReleases) } }
}

private enum NativeVolcURLProtocolPlan {
    case response(URLResponse, [Data])
    case error(URLError)
    case redirect(HTTPURLResponse, URLRequest)
}

private final class NativeVolcURLProtocolHarness: @unchecked Sendable {
    static let shared = NativeVolcURLProtocolHarness()
    private let lock = NSLock()
    private var plans: [NativeVolcURLProtocolPlan] = []
    private(set) var requests: [URLRequest] = []

    func enqueue(_ plan: NativeVolcURLProtocolPlan) {
        lock.withLock { plans.append(plan) }
    }

    func take(for request: URLRequest) -> NativeVolcURLProtocolPlan? {
        lock.withLock {
            requests.append(request)
            return plans.isEmpty ? nil : plans.removeFirst()
        }
    }

    func reset() {
        lock.withLock {
            plans.removeAll()
            requests.removeAll()
        }
    }

    var lastRequest: URLRequest? { lock.withLock { requests.last } }
}

private final class NativeVolcStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let plan = NativeVolcURLProtocolHarness.shared.take(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        switch plan {
        case let .response(response, chunks):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        case let .error(error):
            client?.urlProtocol(self, didFailWithError: error)
        case let .redirect(response, request):
            client?.urlProtocol(self, wasRedirectedTo: request, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private actor NativeVolcTransportStartGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@main
@MainActor
enum NativeVolcDebugTransportTests {
    private static var passed = 0

    static func main() async {
        await testExactRequestAndSuccess()
        await testOfficialEnvelope()
        await testRedirectAndFinalURLRejection()
        await testStreamingCap()
        await testErrorClassificationAndLeaseCompletion()
        await testPreCancelledTaskNeverResumes()
        await testCancelAtDelegateStartReleasesExactlyOnce()
        testChallengePolicy()
        testInvalidSignedRequestFailsBeforeSession()
        print("NativeVolcDebugTransportTests: \(passed) passed")
    }

    private static func expect(
        _ condition: Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition else { fatalError("\(message) (\(file):\(line))") }
        passed += 1
    }

    private static func makeTransport(
        beforeDelegateStart: @escaping @Sendable () async -> Void = {}
    ) -> NativeVolcDebugTransport {
        NativeVolcDebugTransport(
            configurationFactory: NativeVolcTransportConfigurationFactory(make: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [NativeVolcStubURLProtocol.self]
                return configuration
            }, beforeDelegateStart: beforeDelegateStart)
        )
    }

    private static func signedRequest() -> VolcV4SignedRequest {
        try! VolcV4RequestBuilder.build(
            text: NativeVolcDebugFixture.sourceText,
            credentials: VolcV4Credentials(
                accessKey: "AKTEST",
                secretKey: "SKTEST",
                fingerprint: "fixture"
            ),
            sourceLanguage: NativeVolcDebugFixture.sourceLanguage,
            targetLanguage: NativeVolcDebugFixture.targetLanguage,
            instant: Date(timeIntervalSince1970: 1_767_323_045)
        )
    }

    private static func http(
        url: String = NativeVolcDebugFixture.exactEndpoint,
        status: Int = 200,
        headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private static func testExactRequestAndSuccess() async {
        NativeVolcURLProtocolHarness.shared.reset()
        let body = Data(#"{"TranslationList":[{"Translation":"好工具应该毫不费力。"}]}"#.utf8)
        NativeVolcURLProtocolHarness.shared.enqueue(.response(http(), [body]))
        let lease = NativeVolcFakeTransportLease()
        let result = await makeTransport().execute(signedRequest(), lease: lease)
        guard case let .response(status, data) = result else {
            fatalError("expected HTTP response")
        }
        expect(status == 200 && data == body, "transport returns exact status and bytes")
        let request = NativeVolcURLProtocolHarness.shared.lastRequest
        expect(request?.url?.absoluteString == NativeVolcDebugFixture.exactEndpoint,
               "request uses the one fixed origin/path/query")
        expect(request?.httpMethod == "POST", "request is POST")
        expect(request?.cachePolicy == .reloadIgnoringLocalCacheData, "request bypasses URL cache")
        expect(request?.httpShouldHandleCookies == false, "request rejects cookies")
        expect(NativeVolcDebugTransport.makeRequest(signedRequest())?.httpBody == signedRequest().body,
               "signed and configured body Data are identical")
        expect(request?.value(forHTTPHeaderField: "Authorization") == signedRequest().headers["Authorization"],
               "request carries the deterministic authorization header")
        expect(lease.counts.0 == 1 && lease.counts.1 == 1,
               "gate releases after resume and transport after didComplete")
        expect(VolcTranslationResponseParser.parse(statusCode: status, data: data)
            == .success("好工具应该毫不费力。"), "response feeds pure parser")
    }

    private static func testOfficialEnvelope() async {
        NativeVolcURLProtocolHarness.shared.reset()
        let body = Data(#"{"Result":{"TranslationList":[{"Translation":"官方结构"}]}}"#.utf8)
        NativeVolcURLProtocolHarness.shared.enqueue(.response(http(), [body]))
        let result = await makeTransport().execute(
            signedRequest(), lease: NativeVolcFakeTransportLease()
        )
        guard case let .response(status, data) = result else { fatalError("response expected") }
        expect(VolcTranslationResponseParser.parse(statusCode: status, data: data)
            == .success("官方结构"), "official Result shape remains pure-parser compatible")
    }

    private static func testRedirectAndFinalURLRejection() async {
        NativeVolcURLProtocolHarness.shared.reset()
        let redirected = URLRequest(url: URL(string: "https://example.com/")!)
        NativeVolcURLProtocolHarness.shared.enqueue(
            .redirect(http(status: 302), redirected)
        )
        let redirectResult = await makeTransport().execute(
            signedRequest(), lease: NativeVolcFakeTransportLease()
        )
        expect(redirectResult == .failure(.transportSecurity), "every redirect is rejected")

        NativeVolcURLProtocolHarness.shared.enqueue(
            .response(http(url: "https://example.com/"), [Data("{}".utf8)])
        )
        let finalURLResult = await makeTransport().execute(
            signedRequest(), lease: NativeVolcFakeTransportLease()
        )
        expect(finalURLResult == .failure(.transportSecurity), "final URL mismatch fails closed")

        let nonHTTP = URLResponse(
            url: URL(string: NativeVolcDebugFixture.exactEndpoint)!,
            mimeType: "application/json",
            expectedContentLength: 2,
            textEncodingName: "utf-8"
        )
        NativeVolcURLProtocolHarness.shared.enqueue(.response(nonHTTP, [Data("{}".utf8)]))
        let nonHTTPResult = await makeTransport().execute(
            signedRequest(), lease: NativeVolcFakeTransportLease()
        )
        expect(nonHTTPResult == .failure(.transportSecurity), "non-HTTP response fails closed")
    }

    private static func testStreamingCap() async {
        NativeVolcURLProtocolHarness.shared.reset()
        let cap = VolcTranslationResponseParser.maximumPayloadBytes
        NativeVolcURLProtocolHarness.shared.enqueue(
            .response(http(), [Data(repeating: 0x20, count: cap / 2),
                               Data(repeating: 0x20, count: cap - cap / 2)])
        )
        let exact = await makeTransport().execute(
            signedRequest(), lease: NativeVolcFakeTransportLease()
        )
        guard case let .response(_, data) = exact else { fatalError("exact cap accepted") }
        expect(data.count == cap, "exactly 1 MiB is accepted")

        NativeVolcURLProtocolHarness.shared.enqueue(
            .response(http(), [Data(repeating: 0x20, count: cap), Data([0x20])])
        )
        let overflow = await makeTransport().execute(
            signedRequest(), lease: NativeVolcFakeTransportLease()
        )
        expect(overflow == .failure(.transportSecurity), "1 MiB plus one byte is cancelled")

        NativeVolcURLProtocolHarness.shared.enqueue(
            .response(http(headers: ["Content-Length": String(cap + 1)]), [])
        )
        let declared = await makeTransport().execute(
            signedRequest(), lease: NativeVolcFakeTransportLease()
        )
        expect(declared == .failure(.transportSecurity), "declared oversize is rejected before body")
    }

    private static func testErrorClassificationAndLeaseCompletion() async {
        let cases: [(URLError.Code, NativeVolcTransportFailure)] = [
            (.cancelled, .cancelled),
            (.timedOut, .timeout),
            (.serverCertificateUntrusted, .transportSecurity),
            (.cannotConnectToHost, .network),
        ]
        for (code, expected) in cases {
            NativeVolcURLProtocolHarness.shared.enqueue(.error(URLError(code)))
            let lease = NativeVolcFakeTransportLease()
            let result = await makeTransport().execute(signedRequest(), lease: lease)
            expect(result == .failure(expected), "URL error maps to stable typed failure")
            expect(lease.counts == (1, 1), "all terminal paths release each lease exactly once")
        }
    }

    private static func testInvalidSignedRequestFailsBeforeSession() {
        let valid = signedRequest()
        let invalid = VolcV4SignedRequest(
            method: valid.method,
            scheme: valid.scheme,
            host: "example.com",
            canonicalURI: valid.canonicalURI,
            canonicalQuery: valid.canonicalQuery,
            headers: valid.headers,
            body: valid.body,
            canonicalRequest: valid.canonicalRequest,
            stringToSign: valid.stringToSign
        )
        expect(NativeVolcDebugTransport.makeRequest(invalid) == nil,
               "alternate host cannot become a URLRequest")

        var extraHeaders = valid.headers
        extraHeaders["Cookie"] = "secret=value"
        let extraHeader = VolcV4SignedRequest(
            method: valid.method,
            scheme: valid.scheme,
            host: valid.host,
            canonicalURI: valid.canonicalURI,
            canonicalQuery: valid.canonicalQuery,
            headers: extraHeaders,
            body: valid.body,
            canonicalRequest: valid.canonicalRequest,
            stringToSign: valid.stringToSign
        )
        expect(NativeVolcDebugTransport.makeRequest(extraHeader) == nil,
               "extra credential/cookie header is rejected")

        let alternateBody = try! VolcV4RequestBuilder.deterministicBody(
            text: "user text must never enter this Debug adapter",
            sourceLanguage: NativeVolcDebugFixture.sourceLanguage,
            targetLanguage: NativeVolcDebugFixture.targetLanguage
        )
        var alternateHeaders = valid.headers
        alternateHeaders["X-Content-Sha256"] = VolcV4RequestBuilder.sha256Hex(alternateBody)
        let alternateFixture = VolcV4SignedRequest(
            method: valid.method,
            scheme: valid.scheme,
            host: valid.host,
            canonicalURI: valid.canonicalURI,
            canonicalQuery: valid.canonicalQuery,
            headers: alternateHeaders,
            body: alternateBody,
            canonicalRequest: valid.canonicalRequest,
            stringToSign: valid.stringToSign
        )
        expect(NativeVolcDebugTransport.makeRequest(alternateFixture) == nil,
               "non-fixture body cannot become a URLRequest")

        var malformedDateHeaders = valid.headers
        malformedDateHeaders["X-Date"] = "2026-W01-invalid"
        let malformedDate = VolcV4SignedRequest(
            method: valid.method, scheme: valid.scheme, host: valid.host,
            canonicalURI: valid.canonicalURI, canonicalQuery: valid.canonicalQuery,
            headers: malformedDateHeaders, body: valid.body,
            canonicalRequest: valid.canonicalRequest, stringToSign: valid.stringToSign
        )
        expect(NativeVolcDebugTransport.makeRequest(malformedDate) == nil,
               "malformed or week-year X-Date is rejected at the network sink")

        var malformedAuthorizationHeaders = valid.headers
        malformedAuthorizationHeaders["Authorization"] =
            "HMAC-SHA256 Credential=AKTEST/20260102/cn-north-1/translate/request, "
            + "SignedHeaders=content-type;host;x-content-sha256;x-date, Signature=SECRET-CANARY"
        let malformedAuthorization = VolcV4SignedRequest(
            method: valid.method, scheme: valid.scheme, host: valid.host,
            canonicalURI: valid.canonicalURI, canonicalQuery: valid.canonicalQuery,
            headers: malformedAuthorizationHeaders, body: valid.body,
            canonicalRequest: valid.canonicalRequest, stringToSign: valid.stringToSign
        )
        expect(NativeVolcDebugTransport.makeRequest(malformedAuthorization) == nil,
               "non-hex or wrong-length Authorization signature is rejected")
    }

    private static func testPreCancelledTaskNeverResumes() async {
        NativeVolcURLProtocolHarness.shared.reset()
        let lease = NativeVolcFakeTransportLease()
        let result = await Task { () -> NativeVolcTransportResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await makeTransport().execute(signedRequest(), lease: lease)
        }.value
        expect(result == .failure(.cancelled), "pre-cancel is silent and typed")
        expect(NativeVolcURLProtocolHarness.shared.lastRequest == nil,
               "pre-cancelled operation never resumes a URLSession task")
        expect(lease.counts == (1, 1), "pre-cancel releases both locks without network")
    }

    private static func testCancelAtDelegateStartReleasesExactlyOnce() async {
        NativeVolcURLProtocolHarness.shared.reset()
        let gate = NativeVolcTransportStartGate()
        let lease = NativeVolcFakeTransportLease()
        let operation = Task {
            await makeTransport(beforeDelegateStart: { await gate.suspend() })
                .execute(signedRequest(), lease: lease)
        }
        await gate.waitUntilEntered()
        operation.cancel()
        await gate.release()
        expect(await operation.value == .failure(.cancelled),
               "cancel between task creation and delegate start is typed cancelled")
        for _ in 0..<20 { await Task.yield() }
        expect(NativeVolcURLProtocolHarness.shared.lastRequest == nil,
               "delegate-start cancellation never resumes the URLSession task")
        expect(lease.counts == (1, 1),
               "delegate-start and didComplete race releases each lease exactly once")
    }

    private static func testChallengePolicy() {
        expect(NativeVolcTransportChallengePolicy.allowsDefaultServerTrust(
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            host: "translate.volcengineapi.com",
            protocolName: "https",
            port: 443,
            hasServerTrust: true
        ), "only fixed-origin server trust may use system default handling")
        let rejected: [(String, String, String?, Int, Bool)] = [
            (NSURLAuthenticationMethodClientCertificate,
             "translate.volcengineapi.com", "https", 443, true),
            (NSURLAuthenticationMethodServerTrust, "example.com", "https", 443, true),
            (NSURLAuthenticationMethodServerTrust,
             "translate.volcengineapi.com", "http", 443, true),
            (NSURLAuthenticationMethodServerTrust,
             "translate.volcengineapi.com", "https", 8443, true),
            (NSURLAuthenticationMethodServerTrust,
             "translate.volcengineapi.com", "https", 443, false),
        ]
        for value in rejected {
            expect(!NativeVolcTransportChallengePolicy.allowsDefaultServerTrust(
                authenticationMethod: value.0,
                host: value.1,
                protocolName: value.2,
                port: value.3,
                hasServerTrust: value.4
            ), "session/task challenge policy cancels every non-fixed server trust case")
        }
    }
}
#endif
