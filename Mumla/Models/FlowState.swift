enum FlowState: Sendable, Equatable {
    case idle
    case recording
    case processing
    case success
    case error(message: String)
}
