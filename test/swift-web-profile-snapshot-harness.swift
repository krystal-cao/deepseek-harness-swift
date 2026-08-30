import Foundation
import Darwin

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
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

        let profile = root.appendingPathComponent("profiles/web", isDirectory: true)
        let package = profile.appendingPathComponent("package.json")
        let moduleMarker = profile
            .appendingPathComponent("node_modules/plugin", isDirectory: true)
            .appendingPathComponent("marker")
        try fileManager.createDirectory(at: moduleMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"dependencies":{"plugin":"1.0.0"}}"#.utf8).write(to: package, options: .atomic)
        try Data("before".utf8).write(to: moduleMarker, options: .atomic)

        let manager = DshPluginManager.shared
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
        try? fileManager.removeItem(at: root)

        print("web profile snapshot integration harness passed")
    }
}
