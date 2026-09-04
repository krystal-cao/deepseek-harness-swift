import CryptoKit
import Foundation

func requireRecoveryProfile(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func recoveryFingerprint(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

final class FailingRemoveFileSystem: DshRecoveryFileSystem {
    private let local = DshLocalRecoveryFileSystem()
    var failProfileRemoval = false
    var failStateRemoval = false
    var failHomePatchRemoval = false

    func fileExists(_ url: URL) -> Bool { local.fileExists(url) }
    func isDirectory(_ url: URL) -> Bool { local.isDirectory(url) }
    func isSymbolicLink(_ url: URL) -> Bool { local.isSymbolicLink(url) }
    func createDirectory(_ url: URL) throws { try local.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws { try local.write(data, to: url) }
    func read(_ url: URL, maximumBytes: Int) throws -> Data {
        try local.read(url, maximumBytes: maximumBytes)
    }
    func list(_ url: URL) throws -> [URL] { try local.list(url) }

    func remove(_ url: URL) throws {
        if failStateRemoval && url.lastPathComponent == "dsh-recovery-state.json" {
            throw NSError(domain: "RecoveryHarness", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "injected recovery state removal failure"
            ])
        }
        if failHomePatchRemoval && url.lastPathComponent == "cordis.patch.yml" {
            throw NSError(domain: "RecoveryHarness", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "injected recovery home patch removal failure"
            ])
        }
        if failProfileRemoval && url.lastPathComponent.hasPrefix("dsh-recovery-") {
            throw NSError(domain: "RecoveryHarness", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "injected recovery directory removal failure"
            ])
        }
        try local.remove(url)
    }
}

@main
struct RecoveryProfileHarness {
    static func main() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("dsh-recovery-profile-harness-\(UUID().uuidString)", isDirectory: true)
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/recovery-profile", isDirectory: true)
        let originalHome = root.appendingPathComponent("original-home", isDirectory: true)
        let recoveryHome = root.appendingPathComponent("recovery-home", isDirectory: true)
        let managedVersions = root.appendingPathComponent("dsh-versions", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try! fileManager.createDirectory(
            at: originalHome.appendingPathComponent("profiles/desktop", isDirectory: true),
            withIntermediateDirectories: true
        )
        let originalManifest = Data(#"{"name":"original-user-profile","secret":"must-remain-byte-identical"}"#.utf8)
        let originalPatch = Data("original user patch must remain untouched".utf8)
        let originalManifestURL = originalHome.appendingPathComponent("profiles/desktop/package.json")
        let originalPatchURL = originalHome.appendingPathComponent("profiles/desktop/cordis.patch.yml")
        try! originalManifest.write(to: originalManifestURL, options: .atomic)
        try! originalPatch.write(to: originalPatchURL, options: .atomic)
        let originalManifestBefore = try! Data(contentsOf: originalManifestURL)
        let originalPatchBefore = try! Data(contentsOf: originalPatchURL)

        let template = DshRecoveryProfileTemplate(
            officialBaseWebAppFiles: [
                "package.json": try! Data(contentsOf: fixtureRoot.appendingPathComponent("official-base/package.json")),
                "web-app/index.html": try! Data(contentsOf: fixtureRoot.appendingPathComponent("web-app/index.html"))
            ],
            bridgeConfigurationFiles: [
                "dsh-bridge/dsh-bridge.json": try! Data(contentsOf: fixtureRoot.appendingPathComponent("bridge/dsh-bridge.json"))
            ]
        )
        let runtime = NpmRuntimeDescriptor(
            version: "0.1.2-alpha.5",
            registry: "https://registry.npmjs.org",
            integrity: "sha512-fixture"
        )
        let transactionID = "profile-transaction-fixture"
        let recoveryID = UUID(uuidString: "C2A4B8A7-D93D-47CB-8EE8-1E0C9E7FEA18")!
        let port = 43123
        let fileSystem = FailingRemoveFileSystem()
        let manager = DshRecoveryProfileManager(
            recoveryHomeDirectory: recoveryHome,
            fileSystem: fileSystem,
            managedVersionsDirectory: managedVersions,
            hasActiveReference: { _ in false }
        )

        let launch = try! manager.enterRecovery(
            originalProfile: .desktop,
            originalDshHome: originalHome,
            runtimeDescriptor: runtime,
            transactionID: transactionID,
            port: port,
            template: template,
            launchID: UUID(uuidString: "B2D23C0F-2F6A-4CB8-BB6D-88F5BE1456B7")!,
            recoveryID: recoveryID
        )
        let recoveryDirectory = launch.context.profileDirectory
        requireRecoveryProfile(
            launch.recoveryHomeDirectory == recoveryHome.standardizedFileURL,
            "launch should expose the isolated recovery DSH_HOME"
        )
        requireRecoveryProfile(
            launch.launchEnvironment["DSH_HOME"] == recoveryHome.standardizedFileURL.path,
            "launch environment should select the isolated DSH_HOME explicitly"
        )
        requireRecoveryProfile(launch.context.port == port, "recovery context should retain explicit port")
        requireRecoveryProfile(
            launch.context.effectiveAccessPolicy == .loopbackOnly,
            "recovery context should force loopback-only access"
        )
        requireRecoveryProfile(
            launch.context.profileDirectory == recoveryDirectory,
            "context should point at the generated recovery Profile"
        )
        requireRecoveryProfile(
            launch.state.originalDshHome == originalHome.standardizedFileURL,
            "state should retain the original DSH_HOME for explicit bridge decisions"
        )
        requireRecoveryProfile(
            launch.sessionReuseCapability.explicitRoot
                == originalHome.appendingPathComponent("sessions", isDirectory: true).standardizedFileURL,
            "alpha5 should expose only the verified explicit sessions root"
        )
        let homePatchURL = recoveryHome.appendingPathComponent("cordis.patch.yml")
        let homePatch = String(data: try! Data(contentsOf: homePatchURL), encoding: .utf8) ?? ""
        requireRecoveryProfile(homePatch.contains("session-persistence-jsonl"), "recovery home should contain the fixed session bridge patch")
        requireRecoveryProfile(homePatch.contains(originalHome.appendingPathComponent("sessions").path), "session bridge patch should use the original sessions root")
        requireRecoveryProfile(!homePatch.contains("!!js"), "session bridge patch must use an ordinary YAML string")
        requireRecoveryProfile(!homePatch.contains("settings"), "recovery must not inherit settings")
        requireRecoveryProfile(!homePatch.contains("credentials"), "recovery must not inherit credentials")

        let recoveryManifestURL = recoveryDirectory.appendingPathComponent("package.json")
        let recoveryWebAppURL = recoveryDirectory.appendingPathComponent("web-app/index.html")
        let bridgeURL = recoveryDirectory.appendingPathComponent("dsh-bridge/dsh-bridge.json")
        requireRecoveryProfile(fileManager.fileExists(atPath: recoveryManifestURL.path), "base manifest should be materialized")
        requireRecoveryProfile(fileManager.fileExists(atPath: recoveryWebAppURL.path), "official web app should be materialized")
        requireRecoveryProfile(fileManager.fileExists(atPath: bridgeURL.path), "bridge configuration should be materialized")
        requireRecoveryProfile(
            !fileManager.fileExists(atPath: recoveryDirectory.appendingPathComponent("cordis.patch.yml").path),
            "normal Profile patch must not be copied"
        )
        requireRecoveryProfile(
            !fileManager.fileExists(atPath: recoveryDirectory.appendingPathComponent("node_modules").path),
            "normal Profile node_modules must not be copied"
        )

        let proofPackages: [(name: String, version: String, path: String, source: DshRecoveryPackageProofSource)] = [
            (
                "@deepseek-ai/dsh-base",
                runtime.version,
                "node_modules/@deepseek-ai/dsh-base/package.json",
                .managedRuntime
            ),
            (
                "@deepseek-ai/dsh-web-app",
                runtime.version,
                "node_modules/@deepseek-ai/dsh-web-app/package.json",
                .managedRuntime
            ),
            (
                "dsh-desktop-host",
                "1.0.0",
                "node_modules/dsh-desktop-host/package.json",
                .recoveryProfile
            ),
            (
                "@deepseek-ai/dsh-host-webserver",
                runtime.version,
                "node_modules/@deepseek-ai/dsh-host-webserver/package.json",
                .recoveryProfile
            )
        ]
        let packageJSONData: (String, String) -> Data = { name, version in
            Data("{\"name\":\"\(name)\",\"version\":\"\(version)\"}".utf8)
        }
        // Materialize only part of the coordinator's promised install first.
        // A complete directory shape must not be enough to persist `.prepared`.
        for package in proofPackages.dropLast() {
            let packageRoot = package.source == .managedRuntime
                ? managedVersions.appendingPathComponent(runtime.version, isDirectory: true)
                : recoveryDirectory
            let packageURL = packageRoot.appendingPathComponent(package.path)
            try! fileManager.createDirectory(
                at: packageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try! packageJSONData(package.name, package.version).write(to: packageURL, options: .atomic)
        }
        let bridgeManifestData = try! Data(contentsOf: bridgeURL)
        let preparationProof = DshRecoveryPreparationProof(
            runtimeVersion: runtime.version,
            packageManifests: proofPackages.map {
                DshRecoveryPackageProof(
                    name: $0.name,
                    version: $0.version,
                    manifestRelativePath: $0.path,
                    source: $0.source
                )
            },
            bridge: DshRecoveryBridgeProof(
                manifestRelativePath: "dsh-bridge/dsh-bridge.json",
                fingerprint: recoveryFingerprint(bridgeManifestData),
                manifestBytes: bridgeManifestData
            )
        )
        do {
            _ = try manager.markPrepared(recoveryID: recoveryID, proof: preparationProof)
            requireRecoveryProfile(false, "partial Runtime install must not become prepared")
        } catch let error as DshRecoveryError {
            requireRecoveryProfile(
                error.localizedDescription.contains("准备证明"),
                "partial Runtime install should fail through preparation proof validation"
            )
        } catch {
            requireRecoveryProfile(false, "partial Runtime install should use the manager error type")
        }
        switch manager.readState() {
        case .loaded(let state):
            requireRecoveryProfile(state.preparation == .requiresPreparation, "failed preparation must remain resumable")
            requireRecoveryProfile(state.preparationProof == nil, "failed preparation must not persist partial proof")
        default:
            requireRecoveryProfile(false, "failed preparation must preserve the recovery record")
        }

        let webServerPackageURL = recoveryDirectory.appendingPathComponent(proofPackages.last!.path)
        try! fileManager.createDirectory(
            at: webServerPackageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! packageJSONData(proofPackages.last!.name, proofPackages.last!.version)
            .write(to: webServerPackageURL, options: .atomic)

        let originalHomePatchData = try! Data(contentsOf: homePatchURL)
        try! (originalHomePatchData + Data("\n# tampered\n".utf8))
            .write(to: homePatchURL, options: .atomic)
        let unavailableForTamperedPatch = manager.validatePersistedSessionReuseCapability(for: launch.state)
        requireRecoveryProfile(
            !unavailableForTamperedPatch.isAvailable,
            "tampered recovery home patch must disable session reuse"
        )
        try! originalHomePatchData.write(to: homePatchURL, options: .atomic)
        let availableForRestoredPatch = manager.validatePersistedSessionReuseCapability(for: launch.state)
        requireRecoveryProfile(
            availableForRestoredPatch.explicitRoot
                == originalHome.appendingPathComponent("sessions", isDirectory: true).standardizedFileURL,
            "restored exact recovery home patch should re-enable the verified sessions root"
        )

        switch manager.readState() {
        case .loaded(let state):
            requireRecoveryProfile(state == launch.state, "entered state should be readable after materialization")
        default:
            requireRecoveryProfile(false, "entered state should not be treated as absent")
        }

        do {
            _ = try manager.markLaunched(recoveryID: recoveryID)
            requireRecoveryProfile(false, "launch must wait for Runtime materialization")
        } catch let error as DshRecoveryError {
            requireRecoveryProfile(error == .preparationRequired, "launch should expose the preparation gate")
        } catch {
            requireRecoveryProfile(false, "preparation gate should use the manager error type")
        }
        let wrongSourceProof = DshRecoveryPreparationProof(
            runtimeVersion: runtime.version,
            packageManifests: proofPackages.map {
                DshRecoveryPackageProof(
                    name: $0.name,
                    version: $0.version,
                    manifestRelativePath: $0.path,
                    source: .recoveryProfile
                )
            },
            bridge: preparationProof.bridge
        )
        do {
            _ = try manager.markPrepared(recoveryID: recoveryID, proof: wrongSourceProof)
            requireRecoveryProfile(false, "base/web proof must not accept the recovery Profile as its source")
        } catch let error as DshRecoveryError {
            requireRecoveryProfile(
                error.localizedDescription.contains("准备证明"),
                "wrong package proof source should fail through preparation validation"
            )
        } catch {
            requireRecoveryProfile(false, "wrong package proof source should use the manager error type")
        }
        let preparedState = try! manager.markPrepared(recoveryID: recoveryID, proof: preparationProof)
        requireRecoveryProfile(preparedState.preparation == .prepared, "prepared state should be persisted")
        let hostManifestURL = recoveryDirectory.appendingPathComponent("node_modules/dsh-desktop-host/package.json")
        let hostManifestBefore = try! Data(contentsOf: hostManifestURL)
        try! packageJSONData("dsh-desktop-host", "tampered-version")
            .write(to: hostManifestURL, options: .atomic)
        do {
            _ = try manager.markLaunched(recoveryID: recoveryID)
            requireRecoveryProfile(false, "tampered prepared package must not launch")
        } catch let error as DshRecoveryError {
            requireRecoveryProfile(
                error.localizedDescription.contains("准备证明"),
                "tampered prepared package should fail through proof validation"
            )
        } catch {
            requireRecoveryProfile(false, "tampered prepared package should use the manager error type")
        }
        try! hostManifestBefore.write(to: hostManifestURL, options: .atomic)
        let launchedState = try! manager.markLaunched(recoveryID: recoveryID)
        let resumedContext = try! manager.makeRecoveryContext(from: launchedState)
        requireRecoveryProfile(resumedContext.port == port, "interrupted entry should reuse persisted explicit port")
        requireRecoveryProfile(resumedContext.effectiveAccessPolicy == .loopbackOnly, "resumed context should remain loopback-only")
        _ = try! manager.markReturned(recoveryID: recoveryID)
        let resumedState = try! manager.markCleanupPending(recoveryID: recoveryID)
        requireRecoveryProfile(resumedState.phase == .cleanupPending, "cleanup phase should persist")

        // Simulate a pnpm-style link inside the recovery tree. Cleanup must
        // remove this directory entry itself and must never inspect/follow the
        // external target.
        let externalStore = root.appendingPathComponent("pnpm-store", isDirectory: true)
        try! fileManager.createDirectory(at: externalStore, withIntermediateDirectories: true)
        let externalMarker = externalStore.appendingPathComponent("must-survive.txt")
        try! Data("external target".utf8).write(to: externalMarker, options: .atomic)
        let pnpmDirectory = recoveryDirectory
            .appendingPathComponent("node_modules/.pnpm", isDirectory: true)
        try! fileManager.createDirectory(at: pnpmDirectory, withIntermediateDirectories: true)
        let pnpmLink = pnpmDirectory.appendingPathComponent("fixture-package")
        try! fileManager.createSymbolicLink(atPath: pnpmLink.path, withDestinationPath: externalStore.path)

        fileSystem.failProfileRemoval = true
        do {
            _ = try manager.cleanup(recoveryID: recoveryID)
            requireRecoveryProfile(false, "injected cleanup failure should throw")
        } catch let error as DshRecoveryError {
            requireRecoveryProfile(error.localizedDescription.contains("清理失败"), "cleanup failure should be explainable")
        } catch {
            requireRecoveryProfile(false, "cleanup failure should use the manager error type")
        }
        requireRecoveryProfile(fileManager.fileExists(atPath: externalMarker.path), "pnpm symlink target must survive cleanup")
        requireRecoveryProfile(!fileManager.fileExists(atPath: pnpmLink.path), "cleanup should remove the pnpm symlink itself")
        switch manager.readState() {
        case .loaded(let state):
            requireRecoveryProfile(state.phase == .cleanupPending, "failed cleanup should leave a retryable record")
        default:
            requireRecoveryProfile(false, "failed cleanup must not erase the recovery record")
        }

        fileSystem.failProfileRemoval = false
        let cleaned = try! manager.cleanup(recoveryID: recoveryID)
        requireRecoveryProfile(cleaned.phase == .cleaned, "successful cleanup should report cleaned")
        requireRecoveryProfile(!fileManager.fileExists(atPath: recoveryDirectory.path), "successful cleanup should remove only recovery directory")
        requireRecoveryProfile(!fileManager.fileExists(atPath: homePatchURL.path), "successful cleanup should remove the generated home patch")
        if case .absent = manager.readState() {
            // expected: the completed record is removed after the owned tree is gone
        } else {
            requireRecoveryProfile(false, "completed cleanup should remove its state record")
        }

        requireRecoveryProfile(try! Data(contentsOf: originalManifestURL) == originalManifestBefore, "original Profile manifest bytes must remain unchanged")
        requireRecoveryProfile(try! Data(contentsOf: originalPatchURL) == originalPatchBefore, "original Profile patch bytes must remain unchanged")

        // Simulate a force exit after the cleaned marker was written but
        // before the state record could be deleted. The next cleanup is
        // idempotent and only finishes that pending record deletion.
        let interruptedHome = root.appendingPathComponent("interrupted-home", isDirectory: true)
        let interruptedManager = DshRecoveryProfileManager(
            recoveryHomeDirectory: interruptedHome,
            fileSystem: fileSystem,
            hasActiveReference: { _ in false }
        )
        let interruptedID = UUID()
        let interruptedLaunch = try! interruptedManager.enterRecovery(
            originalProfile: .desktop,
            originalDshHome: originalHome,
            runtimeDescriptor: runtime,
            transactionID: nil,
            port: port,
            template: template,
            recoveryID: interruptedID
        )
        requireRecoveryProfile(interruptedLaunch.preparation == .requiresPreparation, "interrupted entry should require materialization")
        fileSystem.failStateRemoval = true
        do {
            _ = try interruptedManager.cleanup(recoveryID: interruptedID)
            requireRecoveryProfile(false, "interrupted state deletion should throw")
        } catch let error as DshRecoveryError {
            requireRecoveryProfile(error.localizedDescription.contains("清理失败"), "state deletion failure should be explainable")
        } catch {
            requireRecoveryProfile(false, "state deletion failure should use the manager error type")
        }
        switch interruptedManager.readState() {
        case .loaded(let state):
            requireRecoveryProfile(state.phase == .cleaned, "cleaned marker must survive state deletion interruption")
        default:
            requireRecoveryProfile(false, "cleaned marker should remain readable after interruption")
        }
        fileSystem.failStateRemoval = false
        let retriedCleaned = try! interruptedManager.cleanup(recoveryID: interruptedID)
        requireRecoveryProfile(retriedCleaned.phase == .cleaned, "cleanup retry should remain idempotently cleaned")
        requireRecoveryProfile(!fileManager.fileExists(atPath: interruptedManager.stateFileURL.path), "cleanup retry should remove the stale cleaned record")
        requireRecoveryProfile(!fileManager.fileExists(atPath: interruptedLaunch.context.profileDirectory.path), "cleanup retry should leave no recovery tree")

        let preexistingPatchHome = root.appendingPathComponent("preexisting-patch-home", isDirectory: true)
        try! fileManager.createDirectory(at: preexistingPatchHome, withIntermediateDirectories: true)
        let preexistingPatchURL = preexistingPatchHome.appendingPathComponent("cordis.patch.yml")
        let preexistingPatch = Data("caller-owned patch".utf8)
        try! preexistingPatch.write(to: preexistingPatchURL, options: .atomic)
        let preexistingManager = DshRecoveryProfileManager(recoveryHomeDirectory: preexistingPatchHome)
        do {
            _ = try preexistingManager.enterRecovery(
                originalProfile: .desktop,
                originalDshHome: originalHome,
                runtimeDescriptor: runtime,
                transactionID: nil,
                port: port,
                template: template,
                recoveryID: UUID()
            )
            requireRecoveryProfile(false, "pre-existing home patch must block recovery entry")
        } catch let error as DshRecoveryError {
            requireRecoveryProfile(error == .recoveryHomePatchExists, "pre-existing home patch should be classified")
        } catch {
            requireRecoveryProfile(false, "pre-existing home patch should use the manager error type")
        }
        requireRecoveryProfile(try! Data(contentsOf: preexistingPatchURL) == preexistingPatch, "pre-existing home patch must remain byte-identical")
        requireRecoveryProfile(!fileManager.fileExists(atPath: preexistingManager.stateFileURL.path), "blocked entry must not leave a recovery record")

        let patchFailureHome = root.appendingPathComponent("patch-failure-home", isDirectory: true)
        let patchFailureManager = DshRecoveryProfileManager(
            recoveryHomeDirectory: patchFailureHome,
            fileSystem: fileSystem,
            hasActiveReference: { _ in false }
        )
        let patchFailureID = UUID()
        _ = try! patchFailureManager.enterRecovery(
            originalProfile: .desktop,
            originalDshHome: originalHome,
            runtimeDescriptor: runtime,
            transactionID: nil,
            port: port,
            template: template,
            recoveryID: patchFailureID
        )
        fileSystem.failHomePatchRemoval = true
        do {
            _ = try patchFailureManager.cleanup(recoveryID: patchFailureID)
            requireRecoveryProfile(false, "home patch removal failure should throw")
        } catch let error as DshRecoveryError {
            requireRecoveryProfile(error.localizedDescription.contains("清理失败"), "home patch removal failure should be explainable")
        } catch {
            requireRecoveryProfile(false, "home patch removal failure should use the manager error type")
        }
        switch patchFailureManager.readState() {
        case .loaded(let state):
            requireRecoveryProfile(state.phase == .cleaned, "home patch failure should preserve cleaned state")
        default:
            requireRecoveryProfile(false, "home patch failure should leave a retryable record")
        }
        fileSystem.failHomePatchRemoval = false
        _ = try! patchFailureManager.cleanup(recoveryID: patchFailureID)
        requireRecoveryProfile(!fileManager.fileExists(atPath: patchFailureManager.stateFileURL.path), "home patch cleanup retry should remove the record")
        requireRecoveryProfile(!fileManager.fileExists(atPath: patchFailureHome.appendingPathComponent("cordis.patch.yml").path), "home patch cleanup retry should remove the generated patch")

        // Corruption is observable and distinct from an absent record.
        let corruptHome = root.appendingPathComponent("corrupt-home", isDirectory: true)
        let corruptManager = DshRecoveryProfileManager(recoveryHomeDirectory: corruptHome)
        try! fileManager.createDirectory(at: corruptHome, withIntermediateDirectories: true)
        try! Data("{\"schemaVersion\":1,\"recoveryID\":\"bad\"}".utf8)
            .write(to: corruptManager.stateFileURL, options: .atomic)
        if case .corrupted(let detail) = corruptManager.readState() {
            requireRecoveryProfile(!detail.isEmpty, "corrupt state should have an explanation")
        } else {
            requireRecoveryProfile(false, "corrupt state must not be reported as absent")
        }

        // Malicious path and template entries are rejected before a record is
        // created, and therefore cannot escape the isolated Profile root.
        let maliciousManager = DshRecoveryProfileManager(
            recoveryHomeDirectory: root.appendingPathComponent("malicious-home", isDirectory: true)
        )
        do {
            _ = try maliciousManager.enterRecovery(
                originalProfile: .desktop,
                originalDshHome: originalHome,
                runtimeDescriptor: runtime,
                transactionID: nil,
                port: port,
                template: DshRecoveryProfileTemplate(
                    officialBaseWebAppFiles: ["../outside.txt": Data("x".utf8)],
                    bridgeConfigurationFiles: [:]
                ),
                recoveryID: UUID()
            )
            requireRecoveryProfile(false, "template traversal should be rejected")
        } catch let error as DshRecoveryError {
            requireRecoveryProfile(error.localizedDescription.contains("模板路径"), "template traversal should be explainable")
        } catch {
            requireRecoveryProfile(false, "template traversal should use the manager error type")
        }
        requireRecoveryProfile(
            !fileManager.fileExists(atPath: maliciousManager.stateFileURL.path),
            "rejected template must not leave a recovery record"
        )

        let ancestorExternal = root.appendingPathComponent("ancestor-external", isDirectory: true)
        try! fileManager.createDirectory(at: ancestorExternal, withIntermediateDirectories: true)
        let ancestorLink = root.appendingPathComponent("ancestor-link", isDirectory: true)
        try! fileManager.createSymbolicLink(atPath: ancestorLink.path, withDestinationPath: ancestorExternal.path)
        let ancestorManager = DshRecoveryProfileManager(
            recoveryHomeDirectory: ancestorLink.appendingPathComponent("recovery-home", isDirectory: true)
        )
        do {
            _ = try ancestorManager.enterRecovery(
                originalProfile: .desktop,
                originalDshHome: originalHome,
                runtimeDescriptor: runtime,
                transactionID: nil,
                port: port,
                template: template,
                recoveryID: UUID()
            )
            requireRecoveryProfile(false, "symlink ancestor must be rejected")
        } catch let error as DshRecoveryError {
            requireRecoveryProfile(error == .symbolicLinkDetected, "symlink ancestor should be classified")
        } catch {
            requireRecoveryProfile(false, "symlink ancestor should use the manager error type")
        }
        requireRecoveryProfile(!fileManager.fileExists(atPath: ancestorExternal.appendingPathComponent("profiles").path), "symlink ancestor target must remain untouched")

        let symlinkManager = DshRecoveryProfileManager(
            recoveryHomeDirectory: root.appendingPathComponent("symlink-home", isDirectory: true)
        )
        let symlinkProfiles = symlinkManager.profilesDirectory
        try! fileManager.createDirectory(at: symlinkProfiles, withIntermediateDirectories: true)
        let symlinkID = UUID()
        let symlinkName = "dsh-recovery-\(symlinkID.uuidString.lowercased())"
        let external = root.appendingPathComponent("external", isDirectory: true)
        try! fileManager.createDirectory(at: external, withIntermediateDirectories: true)
        let symlinkPath = symlinkProfiles.appendingPathComponent(symlinkName)
        try! fileManager.createSymbolicLink(atPath: symlinkPath.path, withDestinationPath: external.path)
        do {
            _ = try symlinkManager.enterRecovery(
                originalProfile: .desktop,
                originalDshHome: originalHome,
                runtimeDescriptor: runtime,
                transactionID: nil,
                port: port,
                template: template,
                recoveryID: symlinkID
            )
            requireRecoveryProfile(false, "symlink recovery directory must be rejected")
        } catch let error as DshRecoveryError {
            requireRecoveryProfile(error == .symbolicLinkDetected, "symlink rejection should be classified")
        } catch {
            requireRecoveryProfile(false, "symlink rejection should use the manager error type")
        }
        requireRecoveryProfile(fileManager.fileExists(atPath: external.path), "symlink target must remain untouched")

        let activeManager = DshRecoveryProfileManager(
            recoveryHomeDirectory: root.appendingPathComponent("active-home", isDirectory: true),
            hasActiveReference: { _ in true }
        )
        let activeLaunch = try! activeManager.enterRecovery(
            originalProfile: .desktop,
            originalDshHome: originalHome,
            runtimeDescriptor: runtime,
            transactionID: nil,
            port: port,
            template: template,
            recoveryID: UUID()
        )
        do {
            _ = try activeManager.cleanup(recoveryID: activeLaunch.state.recoveryID)
            requireRecoveryProfile(false, "active reference must block cleanup")
        } catch let error as DshRecoveryError {
            requireRecoveryProfile(error == .activeReference, "active reference should be classified")
        } catch {
            requireRecoveryProfile(false, "active reference should use the manager error type")
        }

        print("swift recovery profile harness passed")
    }
}
