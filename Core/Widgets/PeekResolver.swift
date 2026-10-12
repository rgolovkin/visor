struct PeekCandidate: Sendable, Equatable {
    let id: String
    let priority: Int
    let isActive: Bool
    /// Position in config order; lower wins a priority tie.
    let order: Int
}

enum PeekResolver {
    /// Candidates must already be limited to enabled widgets.
    static func winner(_ candidates: [PeekCandidate]) -> String? {
        candidates
            .filter(\.isActive)
            .min { lhs, rhs in
                lhs.priority != rhs.priority ? lhs.priority > rhs.priority : lhs.order < rhs.order
            }?
            .id
    }
}
