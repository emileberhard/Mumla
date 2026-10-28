import SpeechKit

extension SpeechKitError: StructuredDiagnosticError {
    nonisolated var diagnosticCode: Int? {
        switch self {
        case .httpFailure(let code, _), .webSocketHandshakeFailed(let code), .webSocketClosed(let code, _): code
        default: nil
        }
    }

    nonisolated var diagnosticKind: String {
        switch self {
        case .httpFailure: "http_failure"
        case .webSocketHandshakeFailed: "websocket_handshake_failed"
        case .webSocketClosed: "websocket_closed"
        case .invalidConfiguration: "invalid_configuration"
        case .invalidRequest: "invalid_request"
        case .invalidResponse: "invalid_response"
        case .providerFailure: "provider_failure"
        case .relayRejected: "relay_rejected"
        }
    }
}
