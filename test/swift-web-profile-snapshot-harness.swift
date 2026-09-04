import Foundation
import CryptoKit
import Darwin

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func treeDigest(_ root: URL) throws -> String {
    let fileManager = FileManager.default
    let rootPath = root.standardizedFileURL.path
    var entries = [URL]()
    if let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
    ) {
        while let entry = enumerator.nextObject() as? URL {
            entries.append(entry)
        }
    }
    var hasher = SHA256()
    for url in entries.sorted(by: { $0.path < $1.path }) {
        let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        hasher.update(data: Data(relative.utf8))
        hasher.update(data: Data([0, values.isDirectory == true ? 1 : 0]))
        if values.isDirectory != true {
            hasher.update(data: try Data(contentsOf: url))
        }
        hasher.update(data: Data([0]))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

@main
struct WebProfileSnapshotHarness {
    static func main() async throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dsh-profile-snapshot-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? fileManager.removeItem(at: root)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("DSH_HOME", root.path, 1)

        require(
            DshPluginManagerStartupGate.decision(
                profileReadiness: .freshEmpty,
                inspectionIsComplete: false,
                inspectionHasErrors: false
            ) == .allowFreshProfileBootstrap,
            "A genuinely empty Profile may be bootstrapped after the expected incomplete inspection"
        )
        require(
            DshPluginManagerStartupGate.decision(
                profileReadiness: .existingUninitialized,
                inspectionIsComplete: false,
                inspectionHasErrors: false,
                inspectionHasUnknowns: true
            ) == .blockProfileMutation,
            "An existing unresolved Profile must remain blocked"
        )
        require(
            DshPluginManagerStartupGate.decision(
                profileReadiness: .initialized,
                inspectionIsComplete: true,
                inspectionHasErrors: false
            ) == .allowProfileMutation,
            "A complete initialized Profile may be mutated"
        )

        let profile = root.appendingPathComponent("profiles/web", isDirectory: true)
        let package = profile.appendingPathComponent("package.json")
        let moduleMarker = profile
            .appendingPathComponent("node_modules/plugin", isDirectory: true)
            .appendingPathComponent("marker")
        try fileManager.createDirectory(at: moduleMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"dependencies":{"plugin":"1.0.0"}}"#.utf8).write(to: package, options: .atomic)
        try Data("before".utf8).write(to: moduleMarker, options: .atomic)

        let manager = DshPluginManager.shared
        // Route deliberately noisy pnpm output through the manager's error
        // formatter. The helper emits a shaped token and auth headers, plus
        // enough bytes to exercise both diagnostic limits.
        let outputProfile = root.appendingPathComponent("profiles/noisy-pnpm", isDirectory: true)
        setenv("DSH_TEST_PNPM_OUTPUT", "1", 1)
        var outputError: Error?
        do {
            try await manager.addPlugin(
                spec: "file:/controlled-fixture",
                profileDirectory: outputProfile,
                profile: .web
            )
        } catch {
            outputError = error
        }
        unsetenv("DSH_TEST_PNPM_OUTPUT")
        require(outputError != nil, "Noisy pnpm fixture must fail so diagnostics are formatted")
        let outputMessage = outputError?.localizedDescription ?? ""
        let shapedToken = String(repeating: "T", count: 43)
        require(!outputMessage.contains(shapedToken), "Process diagnostics must redact token-shaped credentials")
        require(
            outputMessage.contains("Authorization: Bearer [REDACTED]"),
            "Process diagnostics must redact Authorization headers; prefix: \(outputMessage.prefix(800))"
        )
        require(outputMessage.contains("Cookie: session=[REDACTED]"), "Process diagnostics must redact Cookie headers")
        require(outputMessage.count <= 8_400, "Process diagnostics must have a character limit")
        require(Data(outputMessage.utf8).count <= 33_000, "Process diagnostics must have a byte limit")

        let snapshotID = try await manager.createWebProfileSnapshot()
        try Data(#"{"dependencies":{"plugin":"2.0.0"}}"#.utf8).write(to: package, options: .atomic)
        try Data("after".utf8).write(to: moduleMarker, options: .atomic)
        try await manager.restoreWebProfileSnapshot(snapshotID)
        let restoredPackage = try String(contentsOf: package, encoding: .utf8)
        let restoredMarker = try String(contentsOf: moduleMarker, encoding: .utf8)
        require(restoredPackage.contains("1.0.0"), "Profile manifest must be restored")
        require(restoredMarker == "before", "node_modules must be restored")
        try await manager.deleteWebProfileSnapshot(snapshotID)

        try fileManager.removeItem(at: profile)
        let missingSnapshotID = try await manager.createWebProfileSnapshot()
        try fileManager.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("temporary".utf8).write(to: profile.appendingPathComponent("unexpected"), options: .atomic)
        try await manager.restoreWebProfileSnapshot(missingSnapshotID)
        require(!fileManager.fileExists(atPath: profile.path), "Missing original Profile must restore as absent")
        try await manager.deleteWebProfileSnapshot(missingSnapshotID)
        require(manager.bootstrapReadiness(at: profile) == .freshEmpty, "An absent Profile must be classified as fresh")

        let blockedProfile = root.appendingPathComponent("profiles/existing-uninitialized", isDirectory: true)
        let blockedPayload = blockedProfile.appendingPathComponent("node_modules/user-package/keep", isDirectory: false)
        try fileManager.createDirectory(at: blockedPayload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preserve-existing-profile".utf8).write(to: blockedPayload, options: .atomic)
        require(manager.bootstrapReadiness(at: blockedProfile) == .existingUninitialized, "A non-empty manifestless Profile must be classified as existing")
        let blockedBefore = try treeDigest(blockedProfile)
        var bootstrapError: Error?
        do {
            try manager.bootstrapWebProfileManifestIfMissing(at: blockedProfile, profile: .web)
        } catch {
            bootstrapError = error
        }
        require(bootstrapError != nil, "Bootstrap must reject an existing incomplete Profile")
        let bootstrapMessage = bootstrapError?.localizedDescription ?? ""
        require(bootstrapMessage.contains("web Profile manifest"), "Bootstrap rejection must identify the selected Profile")
        require(!bootstrapMessage.contains("selectedProfile.rawValue"), "Bootstrap rejection must interpolate the selected Profile")
        let blockedAfter = try treeDigest(blockedProfile)
        require(blockedAfter == blockedBefore, "Rejected bootstrap must preserve an existing Profile tree")

        let invalidProfile = root.appendingPathComponent("profiles/invalid", isDirectory: true)
        try fileManager.createDirectory(at: invalidProfile, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: invalidProfile.appendingPathComponent("package.json"), options: .atomic)
        var invalidError: Error?
        do {
            try manager.bootstrapWebProfileManifestIfMissing(at: invalidProfile, profile: .desktop)
        } catch {
            invalidError = error
        }
        let invalidMessage = invalidError?.localizedDescription ?? ""
        require(invalidMessage.contains("desktop Profile manifest"), "Invalid manifest rejection must interpolate the selected Profile")

        // A web Profile may contain a user-owned dependency with the same
        // bridge package name. Without the durable marker written by a
        // managed install, cleanup must fail before invoking pnpm or deleting
        // either the manifest or node_modules entry.
        let ownershipProfile = root.appendingPathComponent("profiles/ownership-web", isDirectory: true)
        let userHost = ownershipProfile.appendingPathComponent("node_modules/dsh-desktop-host", isDirectory: true)
        let userWebServer = ownershipProfile.appendingPathComponent("node_modules/@deepseek-ai/dsh-host-webserver", isDirectory: true)
        try fileManager.createDirectory(at: userHost, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userWebServer, withIntermediateDirectories: true)
        let userPackage = #"{"name":"ownership-web","private":true,"dependencies":{"dsh-desktop-host":"user-local","@deepseek-ai/dsh-host-webserver":"user-local"},"dsh":{"profile":{"bundles":["dsh-desktop-host"]}}}"#
        try Data(userPackage.utf8).write(to: ownershipProfile.appendingPathComponent("package.json"), options: .atomic)
        try Data(#"{"name":"dsh-desktop-host","version":"user"}"#.utf8)
            .write(to: userHost.appendingPathComponent("package.json"), options: .atomic)
        try Data(#"{"name":"@deepseek-ai/dsh-host-webserver","version":"user"}"#.utf8)
            .write(to: userWebServer.appendingPathComponent("package.json"), options: .atomic)
        let userPayload = ownershipProfile.appendingPathComponent("node_modules/dsh-desktop-host/user-file")
        try Data("keep-user-package".utf8).write(to: userPayload, options: .atomic)
        let ownershipBefore = try treeDigest(ownershipProfile)
        var ownershipError: Error?
        do {
            try await manager.removeDesktopHostArtifacts(
                from: .web,
                profileDirectory: ownershipProfile,
                registry: "https://registry.invalid"
            )
        } catch {
            ownershipError = error
        }
        require(ownershipError != nil, "Cleanup must reject an unproven same-name dependency")
        let ownershipMessage = ownershipError?.localizedDescription ?? "missing error"
        require(ownershipMessage.contains("所有权证明"), "Cleanup error must explain the ownership proof requirement: \(ownershipMessage)")
        let ownershipAfter = try treeDigest(ownershipProfile)
        require(ownershipAfter == ownershipBefore, "Rejected cleanup must preserve the complete Profile tree")
        require(fileManager.fileExists(atPath: userPayload.path), "Rejected cleanup must preserve the user package")

        // Exercise the positive ownership path with the controlled assets and
        // pnpm helper installed by the integration wrapper. The manager must
        // write the marker only after installation postconditions pass, then
        // verify and remove exactly that app-owned bridge.
        let managedProfile = root.appendingPathComponent("profiles/managed-web", isDirectory: true)
        let installed = try await manager.ensureDesktopHostPlugin(
            registry: "https://registry.invalid",
            profileDirectory: managedProfile,
            profile: .web,
            runtimeVersion: "9.9.9"
        )
        require(installed, "Controlled pnpm install must materialize the bridge")
        let managedPackage = try String(contentsOf: managedProfile.appendingPathComponent("package.json"), encoding: .utf8)
        require(managedPackage.contains("dsh-profile-web"), "Fresh bootstrap must interpolate the profile name")
        let ownershipMarker = managedProfile.appendingPathComponent(".dsh-desktop-host-ownership.json")
        require(fileManager.fileExists(atPath: ownershipMarker.path), "Managed install must write the ownership marker")
        require(fileManager.fileExists(atPath: managedProfile.appendingPathComponent("node_modules/dsh-desktop-host/package.json").path), "Managed install must materialize the bridge package")
        try await manager.removeDesktopHostArtifacts(
            from: .web,
            profileDirectory: managedProfile,
            registry: "https://registry.invalid"
        )
        require(!fileManager.fileExists(atPath: ownershipMarker.path), "Verified cleanup must remove its ownership marker")
        require(!fileManager.fileExists(atPath: managedProfile.appendingPathComponent("node_modules/dsh-desktop-host").path), "Verified cleanup must remove the owned bridge")

        try? fileManager.removeItem(at: root)

        print("web profile snapshot and ownership integration harness passed")
    }
}
