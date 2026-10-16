import Foundation
import LocalAuthentication

/// Face ID (or the device passcode) before the phone acts as the owner in a
/// way that changes bot permissions (UX-023 decision 2; H-118): publishing or
/// confirming a ruling whose option grants extras.
enum OwnerAuth {
    /// What the owner is asked to do; the words follow it (UX-032).
    enum Action: Equatable {
        case publish, confirm
        /// Ruling on a release (UX-023 decision 2: Approve and Reject ask for Face ID).
        case approve, reject
        /// Approving a lead's board-structure proposal (K7, as release rulings).
        case approveBoardChange

        var question: String {
            switch self {
            case .publish: "Publish this ruling?"
            case .confirm: "Confirm this ruling?"
            case .approve: "Approve this release?"
            case .reject: "Reject this release?"
            case .approveBoardChange: "Approve this board change?"
            }
        }

        var refused: String {
            switch self {
            case .publish: "Not published. Nothing was sent."
            case .confirm: "Not confirmed. Nothing was sent."
            case .approve: "Not approved. Nothing was sent."
            case .reject: "Not rejected. Nothing was sent."
            case .approveBoardChange: "Not approved. Nothing was sent."
            }
        }
    }

    enum Failure: LocalizedError, Equatable {
        /// No Face ID or passcode here; `computer` is where to rule instead.
        case unavailable(computer: String)
        case cancelled(Action)

        var errorDescription: String? {
            switch self {
            case .unavailable(let computer):
                let place = computer.isEmpty ? "your computer" : computer
                return "Set up Face ID or a passcode on this device to rule on access, or do it on \(place), in The Hermes app."
            case .cancelled(let action):
                return action.refused
            }
        }
    }

    /// Throws unless the owner confirms. `reason` shows under the Face ID prompt;
    /// `computer` names where to rule when this device can't ask.
    static func confirm(_ reason: String, action: Action, computer: String) async throws {
        #if DEBUG
        // UI tests on a simulator without Face ID: -ownerAuthStub pass|fail.
        switch UserDefaults.standard.string(forKey: "ownerAuthStub") {
        case "pass": return
        case "fail": throw Failure.cancelled(action)
        default: break
        }
        #endif
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw Failure.unavailable(computer: computer)
        }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw Failure.cancelled(action)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.cancelled(action)
        }
    }
}
