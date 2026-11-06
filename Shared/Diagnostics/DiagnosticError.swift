import Foundation

nonisolated struct DiagnosticError: Error, Sendable {
    let typeName: String
    let domain: String
    let code: Int
    let kind: String?
    let reference: String?

    init(_ error: any Error) {
        if let safe = error as? DiagnosticError {
            self = safe
            return
        }
        typeName = String(reflecting: type(of: error))
        let value = error as NSError
        switch value.domain {
        case NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain:
            domain = value.domain
        default:
            domain = typeName
        }
        if let structured = error as? any StructuredDiagnosticError {
            code = structured.diagnosticCode ?? value.code
            kind = structured.diagnosticKind
            reference = structured.diagnosticReference
            return
        }

        code = value.code
        kind = nil
        reference = nil
    }

    var metadata: [String: String] {
        var values = ["error_type": typeName, "error_domain": domain, "error_code": String(code)]
        values["error_kind"] = kind
        values["service_dictation_id"] = reference
        return values
    }

    var nsError: NSError {
        NSError(domain: domain, code: code, userInfo: [:])
    }
}

nonisolated struct DiagnosticEvent {
    let message: String
    let metadata: [String: String]
    let error: NSError?

    init(message: StaticString, metadata: [String: String], error: (any Error)?) {
        self.message = message.description
        let safe = error.map(DiagnosticError.init)
        self.metadata = metadata.merging(safe?.metadata ?? [:]) { _, safe in safe }
        self.error = safe?.nsError
    }
}

nonisolated protocol StructuredDiagnosticError: Error {
    var diagnosticCode: Int? { get }
    var diagnosticKind: String { get }
    var diagnosticReference: String? { get }
}

extension StructuredDiagnosticError {
    nonisolated var diagnosticReference: String? { nil }
}
