import Foundation

@main
struct DshBrowserAccessLivePolicyHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("browser access policy assertion failed: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() throws {
        let access = try DshAccessController(effectiveAccessPolicy: .loopbackOnly)
        try access.sendBootstrap(entryPath: "/tmp/dsh-runtime.mjs", profileName: "desktop", port: 3080)

        // A policy is not live merely because its control message was written.
        // This models the interval in which Settings has changed but Node has
        // not ACKed yet; opening must remain closed during that interval.
        let enableRevision = try access.sendPolicy(
            ordinaryBrowserEnabled: true,
            networkExposure: .loopback
        )
        expect(!access.currentPolicy.ordinaryBrowserEnabled, "unacknowledged enable stays closed")

        access.commitPolicy(
            revision: enableRevision,
            ordinaryBrowserEnabled: true,
            networkExposure: .loopback
        )
        expect(access.currentPolicy.ordinaryBrowserEnabled, "ACKed enable becomes live")

        let disableRevision = try access.sendPolicy(
            ordinaryBrowserEnabled: false,
            networkExposure: .loopback
        )
        expect(access.currentPolicy.ordinaryBrowserEnabled, "unacknowledged disable does not revoke early")

        access.commitPolicy(
            revision: disableRevision,
            ordinaryBrowserEnabled: false,
            networkExposure: .loopback
        )
        expect(!access.currentPolicy.ordinaryBrowserEnabled, "ACKed disable revokes access")
        print("swift browser access live policy harness passed")
    }
}
