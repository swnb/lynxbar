import Foundation

enum RemediationKind: String, Sendable, Equatable {
    case diskReclamation
    case processTermination
}

enum RemediationRisk: String, Sendable, Equatable {
    case guide
    case recoverable
    case disruptive
    case force
}

enum RemediationState: String, Sendable, Equatable {
    case awaitingConfirmation
    case executing
    case verifying
    case succeeded
    case partial
    case failed
    case cancelled
    case stale
    case expired
}

enum RemediationCompletion: Sendable, Equatable {
    case succeeded
    case partial
    case failed
    case cancelled
}

struct PreparedRemediation: Identifiable, Sendable, Equatable {
    let id: UUID
    let kind: RemediationKind
    let evidenceVersion: UUID
    let selectionID: UUID
    let risk: RemediationRisk
    let preparedAt: Date
    let expiresAt: Date
}

struct RemediationExecutionPermit: Sendable, Equatable {
    let id: UUID
    let preparedID: UUID
    let evidenceVersion: UUID
    let selectionID: UUID
    let issuedAt: Date
}

struct RemediationRecordSnapshot: Sendable, Equatable {
    let prepared: PreparedRemediation
    let state: RemediationState
    let permitID: UUID?
}

enum RemediationCoordinatorError: Error, Sendable, Equatable {
    case unknownPreparedAction
    case invalidState(expected: RemediationState, actual: RemediationState)
    case expired
    case staleEvidence
    case selectionChanged
    case riskMismatch
    case invalidPermit
}

extension RemediationCoordinatorError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unknownPreparedAction:
            return NSLocalizedString(
                "The prepared action is unavailable.",
                comment: ""
            )
        case .invalidState:
            return NSLocalizedString(
                "The action state changed. Refresh and try again.",
                comment: ""
            )
        case .expired:
            return NSLocalizedString(
                "The action confirmation expired. Review the target again.",
                comment: ""
            )
        case .staleEvidence:
            return NSLocalizedString(
                "The evidence changed. Review the target again.",
                comment: ""
            )
        case .selectionChanged:
            return NSLocalizedString(
                "The target selection changed. Confirm the current target again.",
                comment: ""
            )
        case .riskMismatch:
            return NSLocalizedString(
                "The action safety classification changed.",
                comment: ""
            )
        case .invalidPermit:
            return NSLocalizedString(
                "The action confirmation is no longer valid.",
                comment: ""
            )
        }
    }
}
