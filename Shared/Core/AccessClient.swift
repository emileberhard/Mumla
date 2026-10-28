import CloudKit
import CryptoKit
import Foundation

nonisolated struct AccessConfiguration: Sendable {
    let origin: URL
    let cloudKitAPIToken: String

    static func main(bundle: Bundle = .main) -> AccessConfiguration? {
        guard let originValue = bundle.object(forInfoDictionaryKey: "MumlaAccessOrigin") as? String,
              let origin = URL(string: originValue), origin.scheme == "https",
              let token = bundle.object(forInfoDictionaryKey: "MumlaCloudKitAPIToken") as? String,
              !token.isEmpty else { return nil }
        return AccessConfiguration(origin: origin, cloudKitAPIToken: token)
    }
}

nonisolated enum AccessFailure: Error, Equatable, Sendable {
    case iCloudUnavailable(CKAccountStatus)
    case allowanceExhausted
    case allowanceBusy
    case serviceUnavailable
}

nonisolated struct AccessGrant: Sendable {
    static let sampleRate = 16_000
    static let maximumAudioSeconds = 120
    static let progressiveAudioSeconds = 110

    let token: String
    let audioLimitSamples: Int
    let origin: URL

    var audioLimit: TimeInterval { Double(audioLimitSamples) / Double(Self.sampleRate) }
}

nonisolated struct StoredAccessSession: Codable, Equatable, Sendable {
    let token: String
    let expiresAt: Date
    let account: String
}

nonisolated protocol AccessSessionStore: Sendable {
    func load() throws -> StoredAccessSession?
    func save(_ session: StoredAccessSession) throws
    func delete() throws
}

nonisolated protocol AccessIdentity: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    func accountID() async throws -> String
    func webAuthToken() async throws -> String
}

nonisolated struct CloudKitAccessIdentity: AccessIdentity {
    let container: CKContainer
    let apiToken: String

    init(_ configuration: AccessConfiguration) {
        container = CKContainer(identifier: MumlaDataStore.cloudContainerIdentifier)
        apiToken = configuration.cloudKitAPIToken
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    func accountID() async throws -> String {
        let recordName = try await container.userRecordID().recordName
        return SHA256.hash(data: Data(recordName.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func webAuthToken() async throws -> String {
        let operation = CKFetchWebAuthTokenOperation(apiToken: apiToken)
        operation.qualityOfService = .userInitiated
        return try await withCheckedThrowingContinuation { continuation in
            operation.fetchWebAuthTokenResultBlock = { continuation.resume(with: $0) }
            container.privateCloudDatabase.add(operation)
        }
    }
}

nonisolated struct KeychainAccessSessionStore: AccessSessionStore {
    private static let account = "MUMLA_ACCESS_SESSION"

    func load() throws -> StoredAccessSession? {
        guard let value = try KeychainStore.access.read(account: Self.account) else { return nil }
        return try JSONDecoder().decode(StoredAccessSession.self, from: Data(value.utf8))
    }

    func save(_ session: StoredAccessSession) throws {
        let data = try JSONEncoder().encode(session)
        try KeychainStore.access.upsert(account: Self.account, value: String(decoding: data, as: UTF8.self))
    }

    func delete() throws {
        try KeychainStore.access.delete(account: Self.account)
    }
}

actor AccessClient {
    nonisolated static let renewalWindow: TimeInterval = 7 * 24 * 3600
    nonisolated static let retryDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]

    private let origin: URL
    private let identity: any AccessIdentity
    private let store: any AccessSessionStore
    private let transport: URLSession
    private let sleep: @Sendable (Duration) async throws -> Void
    private var cached: StoredAccessSession?
    private var loaded = false
    private var refresh: Task<StoredAccessSession, any Error>?
    private var generation = 0

    init(
        origin: URL,
        identity: any AccessIdentity,
        store: any AccessSessionStore,
        transport: URLSession = AccessClient.makeTransport(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.origin = origin
        self.identity = identity
        self.store = store
        self.transport = transport
        self.sleep = sleep
    }

    nonisolated static func live(store: any AccessSessionStore = KeychainAccessSessionStore()) -> AccessClient? {
        guard let configuration = AccessConfiguration.main() else { return nil }
        return AccessClient(origin: configuration.origin, identity: CloudKitAccessIdentity(configuration), store: store)
    }

    nonisolated static func makeTransport() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }

    func allowance() async throws -> MumlaAccess.Allowance {
        let response: AllowanceEnvelope = try await authorized(verifyingAccount: true) { token in
            self.request("GET", "/v1/access", bearer: token)
        }
        return response.allowance.value
    }

    func reserve(maximumAudioSeconds: Int) async throws -> (AccessGrant, MumlaAccess.Allowance) {
        precondition((1...AccessGrant.maximumAudioSeconds).contains(maximumAudioSeconds))
        let body = try JSONEncoder().encode(["maximum_audio_seconds": maximumAudioSeconds])
        let response: GrantEnvelope = try await authorized(verifyingAccount: false) { token in
            self.request("POST", "/v1/dictations", bearer: token, body: body)
        }
        return (AccessGrant(token: response.token, audioLimitSamples: response.audioLimitSamples, origin: origin), response.allowance.value)
    }

    func endSession() async {
        generation += 1
        refresh?.cancel()
        refresh = nil
        let previous = try? loadedSession()
        cached = nil
        try? store.delete()
        guard let previous else { return }
        _ = try? await transport.data(for: request("DELETE", "/v1/session", bearer: previous.token), delegate: RejectRedirects.shared)
    }

    private func authorized<Response: Decodable>(
        verifyingAccount: Bool,
        _ makeRequest: @Sendable (String) -> URLRequest
    ) async throws -> Response {
        let session = try await currentSession(verifyingAccount: verifyingAccount)
        do {
            return try await send(makeRequest(session.token), retrying: true)
        } catch AccessRequestFailure.invalidSession {
            discard(session)
            let replacement = try await currentSession(verifyingAccount: false)
            do { return try await send(makeRequest(replacement.token), retrying: true) }
            catch AccessRequestFailure.invalidSession { discard(replacement); throw AccessFailure.serviceUnavailable }
        }
    }

    private func currentSession(verifyingAccount: Bool) async throws -> StoredAccessSession {
        if let refresh { return try await refresh.value }
        let stored: StoredAccessSession?
        do { stored = try loadedSession() } catch { stored = nil; try? store.delete() }
        if let stored, !verifyingAccount, stored.expiresAt > .now { return stored }
        let generation = generation
        let task = Task { try await self.refreshedSession(stored, generation: generation, renewing: verifyingAccount) }
        refresh = task
        defer { if self.generation == generation { refresh = nil } }
        return try await task.value
    }

    private func refreshedSession(_ stored: StoredAccessSession?, generation: Int, renewing: Bool) async throws -> StoredAccessSession {
        let status: CKAccountStatus
        do { status = try await identity.accountStatus() } catch { throw AccessFailure.iCloudUnavailable(.couldNotDetermine) }
        guard status == .available else { throw AccessFailure.iCloudUnavailable(status) }
        let account: String
        do { account = try await identity.accountID() } catch { throw Self.failure(fromCloudKit: error) }
        if let stored, stored.account == account, stored.expiresAt > .now {
            guard renewing, stored.expiresAt.timeIntervalSinceNow < Self.renewalWindow else { return stored }
            do {
                let response: SessionEnvelope = try await send(request("POST", "/v1/session/renew", bearer: stored.token), retrying: false)
                return try keep(response, account: account, generation: generation)
            } catch AccessRequestFailure.invalidSession {
                discard(stored)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return stored
            }
        } else if let stored {
            discard(stored)
        }
        return try await enroll(account: account, generation: generation)
    }

    private func enroll(account: String, generation: Int) async throws -> StoredAccessSession {
        var delays = Self.retryDelays[...]
        var refreshedRejectedProof = false
        while true {
            let proof: String
            do { proof = try await identity.webAuthToken() } catch { throw Self.failure(fromCloudKit: error) }
            let body = try JSONEncoder().encode(["web_auth_token": proof])
            do {
                let response: SessionEnvelope = try await send(request("POST", "/v1/sessions", body: body), retrying: false)
                return try keep(response, account: account, generation: generation)
            } catch AccessRequestFailure.invalidSession {
                guard !refreshedRejectedProof else { throw AccessFailure.serviceUnavailable }
                refreshedRejectedProof = true
            } catch AccessRequestFailure.retryable {
                guard let delay = delays.popFirst() else { throw AccessFailure.serviceUnavailable }
                try await sleep(Self.jittered(delay))
            }
        }
    }

    private func keep(_ response: SessionEnvelope, account: String, generation: Int) throws -> StoredAccessSession {
        guard generation == self.generation else { throw CancellationError() }
        let session = StoredAccessSession(token: response.token, expiresAt: response.expiresAt, account: account)
        try store.save(session)
        cached = session
        loaded = true
        return session
    }

    private func discard(_ session: StoredAccessSession) {
        guard cached == session else { return }
        cached = nil
        try? store.delete()
    }

    private func loadedSession() throws -> StoredAccessSession? {
        if !loaded {
            cached = try store.load()
            loaded = true
        }
        return cached
    }

    private func send<Response: Decodable>(_ request: URLRequest, retrying: Bool) async throws -> Response {
        var delays = Self.retryDelays[...]
        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await transport.data(for: request, delegate: RejectRedirects.shared)
            } catch {
                try Task.checkCancellation()
                throw AccessFailure.serviceUnavailable
            }
            guard let http = response as? HTTPURLResponse else { throw AccessFailure.serviceUnavailable }
            if (200..<300).contains(http.statusCode) {
                guard let decoded = try? Self.decoder.decode(Response.self, from: data) else { throw AccessFailure.serviceUnavailable }
                return decoded
            }
            let code = (try? Self.decoder.decode(ErrorEnvelope.self, from: data))?.error.code
            switch http.statusCode {
            case 401: throw AccessRequestFailure.invalidSession
            case 402: throw AccessFailure.allowanceExhausted
            case 409 where code == "allowance_busy": throw AccessFailure.allowanceBusy
            case 503:
                guard retrying else { throw AccessRequestFailure.retryable }
                guard let delay = delays.popFirst() else { throw AccessFailure.serviceUnavailable }
                try await sleep(Self.jittered(delay))
            default: throw AccessFailure.serviceUnavailable
            }
        }
    }

    nonisolated private func request(_ method: String, _ path: String, bearer: String? = nil, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: origin.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    nonisolated private static func failure(fromCloudKit error: any Error) -> any Error {
        if error is CancellationError { return error }
        return switch (error as? CKError)?.code {
        case .notAuthenticated: AccessFailure.iCloudUnavailable(.noAccount)
        case .managedAccountRestricted: AccessFailure.iCloudUnavailable(.restricted)
        case .accountTemporarilyUnavailable: AccessFailure.iCloudUnavailable(.temporarilyUnavailable)
        default: AccessFailure.serviceUnavailable
        }
    }

    nonisolated private static func jittered(_ delay: Duration) -> Duration {
        delay * Double.random(in: 0.5...1.0)
    }

    nonisolated private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(value, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(value, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid timestamp"))
        }
        return decoder
    }()
}

nonisolated private enum AccessRequestFailure: Error {
    case invalidSession
    case retryable
}

nonisolated private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RejectRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

nonisolated private struct AllowancePayload: Decodable {
    let limitSeconds: Double
    let usedSeconds: Double
    let reservedSeconds: Double
    let resetsAt: Date

    var value: MumlaAccess.Allowance {
        MumlaAccess.Allowance(limit: .seconds(limitSeconds), used: .seconds(usedSeconds),
                              reserved: .seconds(reservedSeconds), resetsAt: resetsAt)
    }
}

nonisolated private struct AllowanceEnvelope: Decodable {
    let allowance: AllowancePayload
}

nonisolated private struct SessionEnvelope: Decodable {
    let token: String
    let expiresAt: Date
}

nonisolated private struct GrantEnvelope: Decodable {
    let token: String
    let audioLimitSamples: Int
    let allowance: AllowancePayload
}

nonisolated private struct ErrorEnvelope: Decodable {
    struct Body: Decodable { let code: String }
    let error: Body
}
