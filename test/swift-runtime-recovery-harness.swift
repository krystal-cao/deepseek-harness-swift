import Foundation
import Darwin

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let active = NpmRuntimeDescriptor(
    version: "0.1.1-rc.2",
    registry: "https://registry.npmjs.org",
    integrity: "sha512-active"
)
let candidate = NpmRuntimeDescriptor(
    version: "0.1.2-rc.1",
    registry: "https://registry.npmjs.org",
    integrity: "sha512-candidate"
)

func state(
    phase: DshRuntimeTransactionPhase,
    selected: String?,
    previous: NpmRuntimeDescriptor? = active,
    pending: NpmRuntimeDescriptor? = candidate
) -> DshStateConfig {
    DshStateConfig(
        selectedVersion: selected,
        autoFollowLatest: false,
        runtimeState: DshRuntimeState(
            active: selected == candidate.version ? candidate : active,
            previous: previous,
            pending: pending,
            phase: phase,
            updatePolicy: .notify,
            channel: .latest
        )
    )
}

@main
struct RuntimeRecoveryHarness {
    static func main() {
        let initial = DshRuntimeTransaction.begin(
            active: active,
            candidate: candidate,
            updatePolicy: .notify,
            channel: .latest
        )

        // Inject a candidate-install failure before activation. The old
        // active descriptor must survive the rollback transition.
        var candidateInstallFailure = DshRuntimeTransaction.beginRollback(initial)
        candidateInstallFailure = DshRuntimeTransaction.finishRollback(
            candidateInstallFailure,
            active: active
        )
        require(candidateInstallFailure.active == active, "candidate install failure must keep active")
        require(candidateInstallFailure.pending == nil, "candidate install failure must clear pending")
        require(candidateInstallFailure.phase == .idle, "candidate install failure must settle idle")

        // A rollback failure must remain recoverable. In particular, do not
        // clear previous/pending or pretend the transaction is idle.
        let rollbackFailure = DshRuntimeTransaction.recordRollbackFailure(
            DshRuntimeTransaction.beginRollback(
                DshRuntimeTransaction.activateCandidate(initial)
            ),
            diagnostic: "old runtime did not start"
        )
        require(rollbackFailure.phase == .rollingBack, "rollback failure must remain rolling back")
        require(rollbackFailure.previous == active, "rollback failure must retain previous")
        require(rollbackFailure.pending == candidate, "rollback failure must retain pending")
        require(rollbackFailure.lastDiagnostic == "old runtime did not start", "rollback failure must retain diagnostic")

        // Inject a startup/health failure after switching to candidate. The
        // same rollback path must restore the old descriptor.
        var startupFailure = DshRuntimeTransaction.activateCandidate(initial)
        startupFailure = DshRuntimeTransaction.beginVerification(startupFailure)
        startupFailure = DshRuntimeTransaction.beginRollback(startupFailure)
        startupFailure = DshRuntimeTransaction.finishRollback(startupFailure, active: active)
        require(startupFailure.active == active, "startup failure must restore active")
        require(startupFailure.pending == nil, "startup failure must clear pending")
        require(startupFailure.previous == nil, "startup failure must clear previous")

        let confirmed = DshRuntimeTransaction.confirm(
            DshRuntimeTransaction.beginVerification(
                DshRuntimeTransaction.activateCandidate(initial)
            )
        )
        require(confirmed.active == candidate, "successful transaction must activate candidate")
        require(confirmed.pending == nil, "successful transaction must clear pending")
        require(confirmed.phase == .confirmed, "successful transaction must confirm")

        let snapshotted = DshRuntimeTransaction.attachWebProfileSnapshot(initial, id: "snapshot-id")
        require(snapshotted.webProfileSnapshotID == "snapshot-id", "transaction must retain Profile snapshot id")

        if case .finalizeConfirmed(let recovered) = DshRuntimeRecoveryPlanner.plan(
            state: state(phase: .confirmed, selected: candidate.version),
            installedVersions: [active.version, candidate.version]
        ) {
            require(recovered == candidate, "confirmed candidate should be finalized")
        } else {
            require(false, "confirmed candidate should be finalized")
        }

        for phase in [DshRuntimeTransactionPhase.staging, .switching, .verifying, .rollingBack] {
            if case .rollback(let recovered, let discarded) = DshRuntimeRecoveryPlanner.plan(
                state: state(phase: phase, selected: candidate.version),
                installedVersions: [active.version, candidate.version]
            ) {
                require(recovered == active, "unconfirmed phase should restore previous")
                require(discarded == candidate, "unconfirmed phase should discard candidate")
            } else {
                require(false, "unconfirmed phase should plan rollback")
            }
        }

        if case .reset(let discarded) = DshRuntimeRecoveryPlanner.plan(
            state: state(phase: .verifying, selected: candidate.version, previous: nil),
            installedVersions: [candidate.version]
        ) {
            require(discarded == candidate, "missing previous should reset and discard candidate")
        } else {
            require(false, "missing previous should plan reset")
        }

        require(
            DshRuntimeRecoveryPlanner.plan(
                state: state(phase: .idle, selected: active.version, pending: nil),
                installedVersions: [active.version]
            ) == nil,
            "state without pending transaction should not recover"
        )

        let legacy = try! JSONDecoder().decode(
            DshStateConfig.self,
            from: Data(#"{"selectedVersion":"0.1.1-rc.2"}"#.utf8)
        )
        require(legacy.runtimeState.updatePolicy == .notify, "new state default should be notify")
        require(legacy.autoFollowLatest == false, "new state default should not auto-follow latest")
        require(legacy.runtimeState.webProfileSnapshotID == nil, "legacy state should default without Profile snapshot")

        let nextState = DshRuntimeState(updatePolicy: .automaticStable, channel: .next)
        require(nextState.updatePolicy == .notify, "next channel must never persist automatic updates")
        let alphaState = DshRuntimeState(updatePolicy: .automaticStable, channel: .alpha)
        require(alphaState.updatePolicy == .notify, "alpha channel must never persist automatic updates")

        print("runtime recovery integration harness passed")
    }
}
