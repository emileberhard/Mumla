import CloudKit
import Foundation
import Synchronization
import Testing

@Suite("Access client")
struct AccessClientTests {
    @Test func enrollsWithAProofThenReservesWithTheNewSession() async throws {
        let service = StubAccessService()
        service.reply("POST /v1/sessions", 201, StubAccessService.session("s1", days: 30))
        service.reply("POST /v1/dictations", 201, StubAccessService.grant("g1", samples: 1_760_000))
        let store = MemoryAccessSessionStore()

        let (grant, allowance) = try await service.client(store: store).reserve(maximumAudioSeconds: 110)

        #expect(grant.token == "g1")
        #expect(grant.audioLimitSamples == 1_760_000)
        #expect(grant.origin == service.origin)
        #expect(allowance.available == .seconds(3_600 - 10.5 - 600))
        #expect(store.current?.token == "s1")
        #expect(store.current?.account == FakeAccessIdentity.account)
        let requests = service.requests
        #expect(requests.map(\.route) == ["POST /v1/sessions", "POST /v1/dictations"])
        #expect(try requests[0].json([String: String].self) == ["web_auth_token": "proof-1"])
        #expect(requests[1].authorization == "Bearer s1")
        #expect(try requests[1].json([String: Int].self) == ["maximum_audio_seconds": 110])
    }

    @Test func aRejectedSessionIsReplacedOnceWithAFreshProof() async throws {
        let service = StubAccessService()
        service.reply("POST /v1/dictations", 401, #"{"error":{"code":"invalid_session"}}"#)
        service.reply("POST /v1/sessions", 201, StubAccessService.session("s1", days: 30))
        service.reply("POST /v1/dictations", 201, StubAccessService.grant("g1", samples: 16_000))
        let store = MemoryAccessSessionStore(.init(token: "s0", expiresAt: .now + 20 * 86_400, account: FakeAccessIdentity.account))

        let (grant, _) = try await service.client(store: store).reserve(maximumAudioSeconds: 1)

        #expect(grant.token == "g1")
        #expect(service.requests.map(\.authorization) == ["Bearer s0", nil, "Bearer s1"])
        #expect(store.current?.token == "s1")
    }

    @Test func enrollmentRetriesAnUnavailableServiceWithANewProofEachTime() async throws {
        let service = StubAccessService()
        service.reply("POST /v1/sessions", 503, #"{"error":{"code":"service_busy"}}"#)
        service.reply("POST /v1/sessions", 503, #"{"error":{"code":"service_busy"}}"#)
        service.reply("POST /v1/sessions", 201, StubAccessService.session("s1", days: 30))
        service.reply("GET /v1/access", 200, StubAccessService.allowance)
        let sleeps = Mutex<[Duration]>([])

        _ = try await service.client(sleep: { duration in sleeps.withLock { $0.append(duration) } }).allowance()

        let proofs = try service.requests.filter { $0.route == "POST /v1/sessions" }.map { try $0.json([String: String].self)["web_auth_token"] }
        #expect(proofs == ["proof-1", "proof-2", "proof-3"])
        #expect(sleeps.withLock { $0.count } == 2)
    }

    @Test func anIdentityRejectedTwiceStopsWithoutStoringASession() async throws {
        let service = StubAccessService()
        service.reply("POST /v1/sessions", 401, #"{"error":{"code":"invalid_identity"}}"#)
        service.reply("POST /v1/sessions", 401, #"{"error":{"code":"invalid_identity"}}"#)
        let store = MemoryAccessSessionStore()

        await #expect(throws: AccessFailure.serviceUnavailable) {
            try await service.client(store: store).reserve(maximumAudioSeconds: 110)
        }

        #expect(service.requests.count == 2)
        #expect(store.current == nil)
    }

    @Test func aSessionFromAnotherAccountIsNeverSent() async throws {
        let service = StubAccessService()
        service.reply("POST /v1/sessions", 201, StubAccessService.session("s1", days: 30))
        service.reply("GET /v1/access", 200, StubAccessService.allowance)
        let store = MemoryAccessSessionStore(.init(token: "s0", expiresAt: .now + 20 * 86_400, account: "previous-account"))

        _ = try await service.client(store: store).allowance()

        #expect(service.requests.map(\.route) == ["POST /v1/sessions", "GET /v1/access"])
        #expect(service.requests.last?.authorization == "Bearer s1")
        #expect(store.current?.account == FakeAccessIdentity.account)
    }

    @Test(arguments: [(daysLeft: 3.0, renews: true), (daysLeft: 20.0, renews: false)])
    func foregroundRefreshRenewsOnlyWithinAWeekOfExpiry(daysLeft: Double, renews: Bool) async throws {
        let service = StubAccessService()
        service.reply("POST /v1/session/renew", 200, StubAccessService.session("s2", days: 30))
        service.reply("GET /v1/access", 200, StubAccessService.allowance)
        let store = MemoryAccessSessionStore(.init(token: "s0", expiresAt: .now + daysLeft * 86_400, account: FakeAccessIdentity.account))

        _ = try await service.client(store: store).allowance()

        let expected = renews ? ["POST /v1/session/renew", "GET /v1/access"] : ["GET /v1/access"]
        #expect(service.requests.map(\.route) == expected)
        #expect(service.requests.last?.authorization == (renews ? "Bearer s2" : "Bearer s0"))
    }

    @Test(arguments: [
        (status: 402, body: #"{"error":{"code":"allowance_exhausted"}}"#, failure: AccessFailure.allowanceExhausted),
        (status: 409, body: #"{"error":{"code":"allowance_busy"}}"#, failure: AccessFailure.allowanceBusy),
    ])
    func refusedReservationsReportTheirReason(status: Int, body: String, failure: AccessFailure) async throws {
        let service = StubAccessService()
        service.reply("POST /v1/dictations", status, body)
        let store = MemoryAccessSessionStore(.init(token: "s0", expiresAt: .now + 20 * 86_400, account: FakeAccessIdentity.account))

        await #expect(throws: failure) {
            try await service.client(store: store).reserve(maximumAudioSeconds: 110)
        }
        #expect(service.requests.count == 1)
    }

    @Test func aSignedOutAccountNeverContactsTheService() async throws {
        let service = StubAccessService()

        await #expect(throws: AccessFailure.iCloudUnavailable(.noAccount)) {
            try await service.client(identity: FakeAccessIdentity(status: .noAccount)).allowance()
        }
        #expect(service.requests.isEmpty)
    }

    @Test func endingTheSessionForgetsAndRevokesIt() async throws {
        let service = StubAccessService()
        service.reply("DELETE /v1/session", 204, "")
        let store = MemoryAccessSessionStore(.init(token: "s0", expiresAt: .now + 20 * 86_400, account: FakeAccessIdentity.account))

        await service.client(store: store).endSession()

        #expect(store.current == nil)
        #expect(service.requests.map(\.route) == ["DELETE /v1/session"])
        #expect(service.requests.first?.authorization == "Bearer s0")
    }
}

nonisolated final class MemoryAccessSessionStore: AccessSessionStore {
    private let session: Mutex<StoredAccessSession?>

    init(_ session: StoredAccessSession? = nil) {
        self.session = Mutex(session)
    }

    var current: StoredAccessSession? { session.withLock { $0 } }
    func load() throws -> StoredAccessSession? { current }
    func save(_ session: StoredAccessSession) throws { self.session.withLock { $0 = session } }
    func delete() throws { session.withLock { $0 = nil } }
}

nonisolated final class FakeAccessIdentity: AccessIdentity {
    static let account = "synthetic-account"
    private let status: CKAccountStatus
    private let proofs = Mutex(0)

    init(status: CKAccountStatus = .available) {
        self.status = status
    }

    func accountStatus() async throws -> CKAccountStatus { status }
    func accountID() async throws -> String { Self.account }
    func webAuthToken() async throws -> String {
        "proof-\(proofs.withLock { $0 += 1; return $0 })"
    }
}

nonisolated final class StubAccessService: Sendable {
    struct Request: Sendable {
        let route: String
        let authorization: String?
        let body: Data

        func json<Value: Decodable>(_ type: Value.Type) throws -> Value {
            try JSONDecoder().decode(type, from: body)
        }
    }

    static let allowance = #"{"allowance":{"limit_seconds":3600,"used_seconds":10.5,"reserved_seconds":600,"resets_at":"2026-12-01T00:00:00Z"}}"#

    static func session(_ token: String, days: Double) -> String {
        let expiry = Date.now.addingTimeInterval(days * 86_400).ISO8601Format()
        return #"{"token":"\#(token)","expires_at":"\#(expiry)","subject":"synthetic","allowance":{"limit_seconds":3600,"used_seconds":0,"reserved_seconds":0,"resets_at":"2026-12-01T00:00:00.000Z"}}"#
    }

    static func grant(_ token: String, samples: Int) -> String {
        #"{"token":"\#(token)","claim_expires_at":"2026-11-01T00:00:30Z","request_deadline":"2026-11-01T00:15:00Z","audio_limit_samples":\#(samples),"allowance":{"limit_seconds":3600,"used_seconds":10.5,"reserved_seconds":600,"resets_at":"2026-12-01T00:00:00Z"}}"#
    }

    let origin = URL(string: "https://\(UUID().uuidString.lowercased()).access.test")!
    private let state = Mutex<(replies: [String: [(Int, String)]], requests: [Request])>(([:], []))

    init() {
        StubAccessProtocol.services.withLock { $0[origin.host()!] = self }
    }

    deinit {
        let host = origin.host()!
        StubAccessProtocol.services.withLock { _ = $0.removeValue(forKey: host) }
    }

    var requests: [Request] { state.withLock { $0.requests } }

    func reply(_ route: String, _ status: Int, _ body: String) {
        state.withLock { $0.replies[route, default: []].append((status, body)) }
    }

    func client(
        identity: FakeAccessIdentity = FakeAccessIdentity(),
        store: MemoryAccessSessionStore = MemoryAccessSessionStore(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> AccessClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAccessProtocol.self]
        return AccessClient(origin: origin, identity: identity, store: store, transport: URLSession(configuration: configuration), sleep: sleep)
    }

    fileprivate func respond(to request: URLRequest) -> (Int, String) {
        let route = "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")"
        let recorded = Request(route: route, authorization: request.value(forHTTPHeaderField: "Authorization"), body: Self.body(of: request))
        return state.withLock { state in
            state.requests.append(recorded)
            guard var queue = state.replies[route], !queue.isEmpty else { return (500, "") }
            let reply = queue.removeFirst()
            state.replies[route] = queue
            return reply
        }
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { return data }
            data.append(buffer, count: count)
        }
    }
}

nonisolated final class StubAccessProtocol: URLProtocol {
    static let services = Mutex<[String: StubAccessService]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let service = Self.services.withLock({ $0[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (status, body) = service.respond(to: request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
