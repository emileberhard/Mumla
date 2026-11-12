import DictationLibrary
import SpeechKit
import SpeakerRecognition

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

extension VoiceFilterError: StructuredDiagnosticError {
    nonisolated var diagnosticCode: Int? { nil }

    nonisolated var diagnosticKind: String {
        switch self {
        case .voicesUnavailable: "voices_unavailable"
        case .profileUnreadable: "profile_unreadable"
        case .deadlineExceeded: "deadline_exceeded"
        case .modelMissing: "model_missing"
        }
    }
}

extension DictationLibraryError: StructuredDiagnosticError {
    nonisolated var diagnosticDomain: String? {
        switch self {
        case .cloudFailure(let domain, _), .storageFailure(let domain, _): domain
        default: nil
        }
    }

    nonisolated var diagnosticCode: Int? {
        switch self {
        case .cloudFailure(_, let code), .storageFailure(_, let code): code
        default: nil
        }
    }

    nonisolated var diagnosticKind: String {
        switch self {
        case .invalidConfiguration: "invalid_configuration"
        case .accountUnavailable: "account_unavailable"
        case .accountChanged: "account_changed"
        case .profileUnavailable: "profile_unavailable"
        case .archiveDisabled: "archive_disabled"
        case .capacityExceeded: "capacity_exceeded"
        case .invalidCapture: "invalid_capture"
        case .contentConflict: "content_conflict"
        case .invalidRecord: "invalid_record"
        case .unsupportedVersion: "unsupported_version"
        case .noAudio: "no_audio"
        case .recordingFinished: "recording_finished"
        case .cloudDeletedRequiresDecision: "cloud_deleted_requires_decision"
        case .cloudOriginalMissing: "cloud_original_missing"
        case .notConfigured: "not_configured"
        case .cloudFailure: "cloud_failure"
        case .storageFailure: "storage_failure"
        case .heldCapture: "held_capture"
        }
    }
}
