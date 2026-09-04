import Foundation

@main
struct DshLaunchContextHarness {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("launch context assertion failed: \(message)\n", stderr)
            exit(1)
        }
    }

    static func expectThrows(_ operation: () throws -> Void, _ message: String) {
        do {
            try operation()
            expect(false, message)
        } catch {
            // Expected validation failure.
        }
    }

    static func main() throws {
        let runtime = NpmRuntimeDescriptor(
            version: "1.2.3",
            registry: "https://registry.example.test/",
            installedAt: Date(timeIntervalSince1970: 100)
        )
        let home = DshLaunchContext.defaultDshHome
        let desktopDirectory = DshLaunchContext.profileDirectory(
            forName: "desktop",
            dshHome: home
        )
        let normal = DshLaunchContext(
            launchID: UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!,
            purpose: .normal,
            runtimeDescriptor: runtime,
            profile: .desktop,
            profileName: "desktop",
            profileDirectory: desktopDirectory,
            effectiveDshHome: home,
            effectiveAccessPolicy: DshEffectiveAccessPolicy(
                browserAccessEnabled: true,
                networkExposure: .lan
            ),
            port: 4321
        )
        try normal.validate()
        expect(normal.effectiveDshHome.path == home.path, "home is captured")
        expect(normal.profileDirectory.path == desktopDirectory.path, "profile path uses captured home")
        expect(normal.effectiveAccessPolicy.networkExposure == .lan, "LAN policy is captured")

        let mismatched = DshLaunchContext(
            runtimeDescriptor: runtime,
            profile: .desktop,
            profileName: "desktop",
            profileDirectory: DshLaunchContext.profileDirectory(forName: "web", dshHome: home),
            effectiveDshHome: home,
            effectiveAccessPolicy: .loopbackOnly,
            port: 4321
        )
        expectThrows({ try mismatched.validate() }, "profile name and directory must agree")

        let recoveryName = "dsh-recovery-AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        let recoveryHome = URL(fileURLWithPath: home.path + ".isolated", isDirectory: true)
        let recoveryDirectory = DshLaunchContext.profileDirectory(
            forName: recoveryName,
            dshHome: recoveryHome
        )
        let recovery = DshLaunchContext.makeRecovery(
            launchID: normal.launchID,
            runtimeDescriptor: runtime,
            profile: .desktop,
            profileName: recoveryName,
            profileDirectory: recoveryDirectory,
            effectiveDshHome: recoveryHome,
            originalProfile: .desktop,
            transactionID: nil,
            port: 4321
        )
        try recovery.validate()
        expect(recovery.effectiveAccessPolicy == .loopbackOnly, "recovery is loopback-only")
        expect(recovery.isFresh(in: DshStateConfig(dshPort: 4321)), "recovery does not need a global transaction")
        expect(DshLaunchContext.isValidProfileName("desktop"), "desktop is accepted")
        expect(DshLaunchContext.isValidProfileName("web"), "web is accepted")
        expect(DshLaunchContext.isValidProfileName(recoveryName), "recovery UUID is accepted")
        for invalid in ["other", "../desktop", "/tmp/desktop", ".", "..", ".hidden", "-desktop", "桌面"] {
            expect(!DshLaunchContext.isValidProfileName(invalid), "rejects \(invalid)")
        }

        let profileTransaction = DshProfileSwitchTransaction(
            from: .desktop,
            to: .web,
            startedAt: Date(timeIntervalSince1970: 200),
            transactionID: "profile-transaction"
        )
        let decoder = JSONDecoder()
        let legacyProfile = try decoder.decode(
            DshProfileSwitchTransaction.self,
            from: Data(#"{"from":"desktop","to":"web","phase":"switching","startedAt":200.001}"#.utf8)
        )
        expect(!legacyProfile.transactionID.isEmpty, "legacy Profile transaction receives an owner ID")
        let legacyProfileAtNextMillisecond = try decoder.decode(
            DshProfileSwitchTransaction.self,
            from: Data(#"{"from":"desktop","to":"web","phase":"switching","startedAt":200.002}"#.utf8)
        )
        expect(legacyProfile.transactionID != legacyProfileAtNextMillisecond.transactionID, "adjacent legacy Profile transactions differ")
        let profileState = DshStateConfig(
            appProfile: .web,
            pendingProfileSwitch: profileTransaction,
            runtimeState: DshRuntimeState(active: runtime),
            dshPort: 4321
        )
        expect(DshLaunchContext.makeStartup(from: profileState)?.purpose == .profileSwitch, "target Profile switch purpose")
        var restoredProfileState = profileState
        restoredProfileState.appProfile = .desktop
        expect(DshLaunchContext.makeStartup(from: restoredProfileState)?.purpose == .profileRollback, "restored Profile uses rollback purpose")

        let oldRuntimeJSON = Data(#"{"active":{"version":"1.2.3","registry":"https://registry.example.test","installedAt":100},"previous":{"version":"1.1.0","registry":"https://registry.example.test","installedAt":90},"pending":{"version":"1.3.0","registry":"https://registry.example.test","installedAt":110},"profile":"desktop","phase":"switching","updatePolicy":"notify","channel":"latest"}"#.utf8)
        let legacyA = try decoder.decode(DshRuntimeState.self, from: oldRuntimeJSON)
        let legacyB = try decoder.decode(DshRuntimeState.self, from: oldRuntimeJSON)
        expect(legacyA.transactionID != nil && legacyA.transactionID == legacyB.transactionID, "legacy Runtime ID is stable")
        let changedRuntimeJSON = Data(#"{"active":{"version":"1.2.3","registry":"https://registry.example.test","installedAt":100},"previous":{"version":"1.1.0","registry":"https://registry.example.test","installedAt":90},"pending":{"version":"1.4.0","registry":"https://registry.example.test","installedAt":110},"profile":"desktop","phase":"switching","updatePolicy":"notify","channel":"latest"}"#.utf8)
        let legacyChanged = try decoder.decode(DshRuntimeState.self, from: changedRuntimeJSON)
        expect(legacyA.transactionID != legacyChanged.transactionID, "different legacy Runtime transactions differ")
        let millisecondRuntimeJSON = Data(#"{"active":{"version":"1.2.3","registry":"https://registry.example.test","installedAt":100.001},"previous":{"version":"1.1.0","registry":"https://registry.example.test","installedAt":90},"pending":{"version":"1.3.0","registry":"https://registry.example.test","installedAt":110},"profile":"desktop","phase":"switching","updatePolicy":"notify","channel":"latest","transactionID":null}"#.utf8)
        let legacyAtNextMillisecond = try decoder.decode(DshRuntimeState.self, from: millisecondRuntimeJSON)
        expect(legacyAtNextMillisecond.transactionID != nil, "legacy non-idle Runtime transaction receives an owner ID")
        expect(legacyA.transactionID != legacyAtNextMillisecond.transactionID, "adjacent legacy Runtime transactions differ")
        let idleWithoutTransaction = try decoder.decode(
            DshRuntimeState.self,
            from: Data(#"{"phase":"idle","transactionID":null}"#.utf8)
        )
        expect(idleWithoutTransaction.transactionID == nil, "idle state may have no transaction owner")

        print("effective-home=\(home.path)")
        print("swift launch context harness passed")
    }
}
