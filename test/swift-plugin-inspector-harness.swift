import Foundation
import CryptoKit

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private let fileManager = FileManager.default

private func write(_ root: URL, _ relativePath: String, _ text: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
}

private func package(_ root: URL, _ name: String) -> URL {
    root.appendingPathComponent("node_modules", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
}

private func item(_ result: DshPluginInspectionResult, _ name: String) -> DshPluginInspectionItem {
    guard let value = result.items.first(where: { $0.name == name }) else {
        fatalError("missing inspection item \(name)")
    }
    return value
}

private func treeDigest(_ root: URL) throws -> String {
    let paths = try fileManager.subpathsOfDirectory(atPath: root.path)
        .map { root.appendingPathComponent($0) }
        .sorted { $0.path < $1.path }
    var input = Data()
    for url in paths {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            continue
        }
        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        input.append(Data(relative.utf8))
        input.append(0)
        input.append(try Data(contentsOf: url))
        input.append(0)
    }
    return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
}

private let libraryManifest = #"{"name":"fixture-library","version":"1.0.0"}"#

@main
struct PluginInspectorHarness {
    static func main() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dsh-plugin-inspector-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? fileManager.removeItem(at: root)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let healthy = root.appendingPathComponent("healthy", isDirectory: true)
        let healthyProfile = healthy.appendingPathComponent("profile", isDirectory: true)
        let healthyRuntime = healthy.appendingPathComponent("runtime", isDirectory: true)
        let healthyPackage = #"{"name":"dsh-fixture","private":true,"dependencies":{"dsh-desktop-host":"1.0.0","fixture-library":"1.0.0","runtime-only-library":"1.0.0","@deepseek-ai/dsh-host-webserver":"*"},"dsh":{"profile":{"bundles":["dsh-desktop-host"]}}}"#
        try write(healthyProfile, "package.json", healthyPackage)
        try write(healthyProfile, "pnpm-lock.yaml", "lockfileVersion: '9.0'\nimporters:\n  .:\n    dependencies: {}\n")
        try write(healthyProfile, "node_modules/dsh-desktop-host/package.json", #"{"name":"dsh-desktop-host","version":"1.0.0","dsh":{"bundle":{"patch":"./cordis.patch.yml"}}}"#)
        try write(healthyProfile, "node_modules/dsh-desktop-host/cordis.patch.yml", """
        - id: desktop-host
          name: dsh-desktop-host
        - id: upstream-host
          name: '@deepseek-ai/dsh-host-webserver'
          disabled: true
        - insert:
            - id: desktop-webserver
              name: dsh-desktop-host/webserver
        """)
        try write(healthyProfile, "node_modules/fixture-library/package.json", libraryManifest)
        try write(healthyRuntime, "node_modules/runtime-only-library/package.json", #"{"name":"runtime-only-library","version":"9.9.9"}"#)
        try write(healthyRuntime, "node_modules/@deepseek-ai/dsh-host-webserver/package.json", #"{"name":"@deepseek-ai/dsh-host-webserver","version":"0.1.1"}"#)

        let beforeHealthy = try treeDigest(healthyProfile)
        let healthyResult = await DshPluginInspector(
            profileDirectory: healthyProfile,
            runtimeHostRoot: healthyRuntime
        ).inspectAsync()
        require(!healthyResult.isComplete, "untrusted patch fixture should be incomplete")
        require(healthyResult.hasProblems, "untrusted patch fixture should surface uncertainty")
        require(item(healthyResult, "dsh-desktop-host").kind == .bundle, "desktop host should be a Bundle")
        require(item(healthyResult, "dsh-desktop-host").status == .unavailable, "Bundle state requires a trusted parser")
        require(item(healthyResult, "dsh-desktop-host").confidence == .unknown, "untrusted patch confidence")
        require(item(healthyResult, "fixture-library").kind == .library, "ordinary library must not be a Bundle")
        require(item(healthyResult, "@deepseek-ai/dsh-host-webserver").source == .runtimeHost, "host must resolve from Runtime root")
        require(item(healthyResult, "@deepseek-ai/dsh-host-webserver").status == .healthy, "untrusted patch must not infer disabled host")
        require(item(healthyResult, "runtime-only-library").kind == .library, "Runtime library must not be treated as core")
        require(item(healthyResult, "runtime-only-library").status == .healthy, "Runtime library must remain available")
        require(healthyResult.disabledBundleNames.isEmpty, "untrusted patch must not report disabled names")
        require(healthyResult.bundleOrder == ["dsh-desktop-host"], "Bundle order must come from profile metadata")
        require(healthyResult.issues.contains { $0.code == "patchInspectionUnavailable" }, "missing trusted parser issue")
        let afterHealthy = try treeDigest(healthyProfile)
        require(afterHealthy == beforeHealthy, "manifest, lockfile, patch, and Profile tree must remain unchanged")

        let missing = root.appendingPathComponent("missing", isDirectory: true)
        let missingProfile = missing.appendingPathComponent("profile", isDirectory: true)
        try write(missingProfile, "package.json", #"{"name":"dsh-missing","dependencies":{"missing-bundle":"1.0.0"}}"#)
        let missingResult = DshPluginInspector(profileDirectory: missingProfile, runtimeHostRoot: missing.appendingPathComponent("runtime")).inspect()
        require(!missingResult.isComplete, "missing package must make check incomplete")
        require(item(missingResult, "missing-bundle").status == .missingPackage, "missing package status")
        require(missingResult.issues.contains { $0.code == "packageMissing" }, "missing package issue")

        let malformedDependency = root.appendingPathComponent("malformed-dependency", isDirectory: true)
        let malformedDependencyProfile = malformedDependency.appendingPathComponent("profile", isDirectory: true)
        try write(malformedDependencyProfile, "package.json", #"{"name":"dsh-malformed-dependency","dependencies":{"broken-package":"1.0.0"}}"#)
        try write(malformedDependencyProfile, "node_modules/broken-package/package.json", "{\"name\":\n")
        let malformedDependencyResult = DshPluginInspector(
            profileDirectory: malformedDependencyProfile,
            runtimeHostRoot: malformedDependency.appendingPathComponent("runtime")
        ).inspect()
        require(malformedDependencyResult.issues.contains { $0.code == "materializedManifestInvalid" }, "bad dependency JSON issue")
        require(item(malformedDependencyResult, "broken-package").status == .unavailable, "bad dependency JSON must remain unavailable")

        let disabled = root.appendingPathComponent("disabled", isDirectory: true)
        let disabledProfile = disabled.appendingPathComponent("profile", isDirectory: true)
        try write(disabledProfile, "package.json", #"{"name":"dsh-disabled","dependencies":{"disabled-bundle":"1.0.0"},"dsh":{"profile":{"bundles":["disabled-bundle"]}}}"#)
        try write(disabledProfile, "node_modules/disabled-bundle/package.json", #"{"name":"disabled-bundle","dsh":{"bundle":{"patch":"./cordis.patch.yml"}}}"#)
        try write(disabledProfile, "node_modules/disabled-bundle/cordis.patch.yml", """
        - id: disabled
          name: disabled-bundle
          disabled: true
        """)
        let disabledResult = DshPluginInspector(profileDirectory: disabledProfile, runtimeHostRoot: disabled.appendingPathComponent("runtime")).inspect()
        require(!disabledResult.isComplete, "untrusted patch check is incomplete")
        require(disabledResult.hasProblems, "untrusted patch must be surfaced")
        require(item(disabledResult, "disabled-bundle").status == .unavailable, "untrusted patch must not infer disabled status")
        require(item(disabledResult, "disabled-bundle").confidence == .unknown, "untrusted patch confidence")

        let notComposed = root.appendingPathComponent("not-composed", isDirectory: true)
        let notComposedProfile = notComposed.appendingPathComponent("profile", isDirectory: true)
        try write(notComposedProfile, "package.json", #"{"name":"dsh-not-composed","dependencies":{"orphan-bundle":"1.0.0"},"dsh":{"profile":{"bundles":[]}}}"#)
        try write(notComposedProfile, "node_modules/orphan-bundle/package.json", #"{"name":"orphan-bundle","dsh":{"bundle":{}}}"#)
        let notComposedResult = DshPluginInspector(profileDirectory: notComposedProfile, runtimeHostRoot: notComposed.appendingPathComponent("runtime")).inspect()
        require(item(notComposedResult, "orphan-bundle").status == .notComposed, "uncomposed Bundle status")
        require(notComposedResult.hasProblems, "uncomposed Bundle must be surfaced")

        let malformedPatch = root.appendingPathComponent("malformed-patch", isDirectory: true)
        let malformedPatchProfile = malformedPatch.appendingPathComponent("profile", isDirectory: true)
        try write(malformedPatchProfile, "package.json", #"{"name":"dsh-malformed-patch","dependencies":{"broken-bundle":"1.0.0"},"dsh":{"profile":{"bundles":["broken-bundle"]}}}"#)
        try write(malformedPatchProfile, "node_modules/broken-bundle/package.json", #"{"name":"broken-bundle","dsh":{"bundle":{"patch":"./cordis.patch.yml"}}}"#)
        try write(malformedPatchProfile, "node_modules/broken-bundle/cordis.patch.yml", "- id: broken\n  name: [unterminated\n")
        let malformedPatchResult = DshPluginInspector(profileDirectory: malformedPatchProfile, runtimeHostRoot: malformedPatch.appendingPathComponent("runtime")).inspect()
        require(!malformedPatchResult.isComplete, "malformed patch must be incomplete")
        require(item(malformedPatchResult, "broken-bundle").status == .unavailable, "malformed patch must not confirm Bundle status")
        require(item(malformedPatchResult, "broken-bundle").confidence == .unknown, "malformed patch confidence must be unknown")
        require(malformedPatchResult.issues.contains { $0.code == "patchInspectionUnavailable" }, "untrusted parser must report unavailable")

        let malformedManifest = root.appendingPathComponent("malformed-manifest", isDirectory: true)
        let malformedManifestProfile = malformedManifest.appendingPathComponent("profile", isDirectory: true)
        try write(malformedManifestProfile, "package.json", "{\"dependencies\":")
        let malformedManifestResult = DshPluginInspector(profileDirectory: malformedManifestProfile, runtimeHostRoot: malformedManifest.appendingPathComponent("runtime")).inspect()
        require(!malformedManifestResult.isComplete, "malformed JSON must be incomplete")
        require(malformedManifestResult.issues.contains { $0.code == "profileManifestInvalid" }, "malformed JSON issue")

        let missingManifest = root.appendingPathComponent("missing-manifest", isDirectory: true)
        let missingManifestResult = DshPluginInspector(
            profileDirectory: missingManifest.appendingPathComponent("profile"),
            runtimeHostRoot: missingManifest.appendingPathComponent("runtime")
        ).inspect()
        require(!missingManifestResult.isComplete, "missing Profile manifest must be unavailable")
        require(missingManifestResult.issues.contains { $0.code == "profileManifestMissing" }, "missing Profile manifest issue")

        let mixed = root.appendingPathComponent("mixed-targets", isDirectory: true)
        let mixedProfile = mixed.appendingPathComponent("profile", isDirectory: true)
        try write(mixedProfile, "package.json", #"{"name":"dsh-mixed","dependencies":{"mixed-bundle":"1.0.0"},"dsh":{"profile":{"bundles":["mixed-bundle"]}}}"#)
        try write(mixedProfile, "node_modules/mixed-bundle/package.json", #"{"name":"mixed-bundle","dsh":{"bundle":{"patch":"./cordis.patch.yml"}}}"#)
        try write(mixedProfile, "node_modules/mixed-bundle/cordis.patch.yml", """
        - insert:
            - id: active-root
              name: mixed-bundle
              config:
                name: should-not-be-a-plugin
                disabled: true
            - id: disabled-subpath
              name: mixed-bundle/optional
              disabled: true
        """)
        let mixedResult = DshPluginInspector(profileDirectory: mixedProfile, runtimeHostRoot: mixed.appendingPathComponent("runtime")).inspect()
        require(item(mixedResult, "mixed-bundle").status == .unavailable, "untrusted patch must not infer Bundle state")
        require(item(mixedResult, "mixed-bundle").confidence == .unknown, "untrusted patch confidence")
        require(!mixedResult.items.contains { $0.name == "should-not-be-a-plugin" }, "nested config name must not become a plugin")

        let duplicate = root.appendingPathComponent("duplicate", isDirectory: true)
        let duplicateProfile = duplicate.appendingPathComponent("profile", isDirectory: true)
        try write(duplicateProfile, "package.json", #"{"name":"dsh-duplicate","dependencies":{"root-bundle":"1.0.0"},"dsh":{"profile":{"bundles":["root-bundle"]}}}"#)
        try write(duplicateProfile, "node_modules/root-bundle/package.json", #"{"name":"root-bundle","dependencies":{"transitive-bundle":"1.0.0"},"dsh":{"bundle":{"patch":"./cordis.patch.yml"}}}"#)
        try write(duplicateProfile, "node_modules/transitive-bundle/package.json", #"{"name":"transitive-bundle","dsh":{"bundle":{}}}"#)
        try write(duplicateProfile, "node_modules/root-bundle/cordis.patch.yml", """
        - id: first
          name: root-bundle
        - id: second
          name: root-bundle
        """)
        let duplicateResult = DshPluginInspector(profileDirectory: duplicateProfile, runtimeHostRoot: duplicate.appendingPathComponent("runtime")).inspect()
        require(item(duplicateResult, "root-bundle").status == .unavailable, "untrusted patch must not infer duplicate Bundle status")
        require(item(duplicateResult, "root-bundle").confidence == .unknown, "untrusted patch confidence")
        let transitiveStatus = item(duplicateResult, "transitive-bundle").status
        require(transitiveStatus == .uncertain, "indirect Bundle must be uncertain got \(transitiveStatus)")
        require(!duplicateResult.uncertainties.isEmpty, "indirect dependency uncertainty")
        require(!duplicateResult.issues.contains { $0.code == "duplicateBundle" }, "untrusted parser must not infer duplicate issue")

        let profileDuplicate = root.appendingPathComponent("profile-duplicate", isDirectory: true)
        let profileDuplicateProfile = profileDuplicate.appendingPathComponent("profile", isDirectory: true)
        try write(profileDuplicateProfile, "package.json", #"{"name":"dsh-profile-duplicate","dependencies":{"profile-bundle":"1.0.0"},"dsh":{"profile":{"bundles":["profile-bundle","profile-bundle"]}}}"#)
        try write(profileDuplicateProfile, "node_modules/profile-bundle/package.json", #"{"name":"profile-bundle","dsh":{"bundle":{}}}"#)
        let profileDuplicateResult = DshPluginInspector(
            profileDirectory: profileDuplicateProfile,
            runtimeHostRoot: profileDuplicate.appendingPathComponent("runtime")
        ).inspect()
        require(item(profileDuplicateResult, "profile-bundle").status == .duplicateBundle,
                "only duplicate dsh.profile.bundles entries are duplicate Bundles")
        require(profileDuplicateResult.issues.contains { $0.code == "duplicateBundle" },
                "profile Bundle duplicate issue")

        // A parser is trusted only when the caller supplies the managed
        // Runtime root and its Node binary. Keep this fixture separate from
        // the conservative no-parser cases above.
        if let runtimePath = ProcessInfo.processInfo.environment["DSH_PLUGIN_INSPECTOR_TRUSTED_RUNTIME_ROOT"],
           let nodePath = ProcessInfo.processInfo.environment["DSH_PLUGIN_INSPECTOR_TRUSTED_NODE"] {
            let trusted = root.appendingPathComponent("trusted-parser", isDirectory: true)
            let trustedProfile = trusted.appendingPathComponent("profile", isDirectory: true)
            let trustedRuntime = URL(fileURLWithPath: runtimePath, isDirectory: true)
            let trustedNode = URL(fileURLWithPath: nodePath, isDirectory: false)
            try write(trustedProfile, "package.json", #"{"name":"dsh-trusted","dependencies":{"trusted-bundle":"1.0.0","conflict-bundle":"1.0.0"},"dsh":{"profile":{"bundles":["trusted-bundle","conflict-bundle"]}}}"#)
            try write(trustedProfile, "node_modules/js-yaml/package.json", #"{"name":"js-yaml","version":"0.0.0-profile-fixture"}"#)
            try write(trustedProfile, "node_modules/js-yaml/index.js", "throw new Error('profile parser must not load')\n")
            try write(trustedProfile, "node_modules/trusted-bundle/package.json", #"{"name":"trusted-bundle","dsh":{"bundle":{"patch":"./cordis.patch.yml"}}}"#)
            try write(trustedProfile, "node_modules/conflict-bundle/package.json", #"{"name":"conflict-bundle","dsh":{"bundle":{"patch":"./cordis.patch.yml"}}}"#)
            try write(trustedProfile, "cordis.patch.yml", """
            - id: shared-row
              name: trusted-bundle
              config:
                prompt: |
                  this is a multiline value
                  that must stay opaque to the inspector
            """)
            try write(trustedProfile, "node_modules/trusted-bundle/cordis.patch.yml", """
            - id: shared-row
              name: trusted-bundle
            - id: trusted-second
              name: trusted-bundle
              config:
                value: !!js Number(process.env.DSH_PLUGIN_INSPECTOR_SHOULD_NOT_RUN)
                nested:
                  values: [one, two, three]
            - insert:
                - id: trusted-insert
                  name: trusted-bundle/optional
            """)
            try write(trustedProfile, "node_modules/conflict-bundle/cordis.patch.yml", """
            - id: conflict-row
              name: conflict-bundle
            - id: conflict-row
              name: conflict-bundle
            """)
            let beforeTrusted = try treeDigest(trustedProfile)
            let trustedResult = DshPluginInspector(
                profileDirectory: trustedProfile,
                runtime: DshPluginInspectorRuntimeDescriptor(
                    root: trustedRuntime, nodeBinary: trustedNode, integrityVerified: true)
            ).inspect()
            require(trustedResult.isComplete, "trusted parser fixture should complete: \(trustedResult.issues)")
            require(item(trustedResult, "trusted-bundle").status == .healthy, "different patch ids are legal")
            require(item(trustedResult, "conflict-bundle").status == .healthy, "same patch id must not disable package")
            require(!trustedResult.issues.contains { $0.code == "duplicateBundle" }, "patch ids are not profile Bundle duplicates")
            require(trustedResult.issues.contains { $0.code == "patchOverride" }, "same id override should be visible")
            require(trustedResult.bundleOrder == ["trusted-bundle", "conflict-bundle"], "trusted Bundle order")
            let afterTrusted = try treeDigest(trustedProfile)
            require(afterTrusted == beforeTrusted, "trusted inspection must not mutate Profile")

            // Match pnpm's managed Runtime shape: @deepseek-ai/dsh is linked
            // from the version root while its base/web Bundle dependencies
            // live beside the real package in the virtual store. Also prove
            // that a documented inert !!js disabled expression is accepted.
            let nested = root.appendingPathComponent("nested-runtime", isDirectory: true)
            let nestedProfile = nested.appendingPathComponent("profile", isDirectory: true)
            let nestedRuntime = nested.appendingPathComponent("runtime", isDirectory: true)
            let virtualPackageRoot = nestedRuntime
                .appendingPathComponent("node_modules/.pnpm/dsh-fixture/node_modules", isDirectory: true)
            let realDshPackage = virtualPackageRoot
                .appendingPathComponent("@deepseek-ai/dsh", isDirectory: true)
            try write(nestedProfile, "package.json", #"{"name":"dsh-nested","dependencies":{"dynamic-bundle":"1.0.0"},"dsh":{"profile":{"bundles":["@deepseek-ai/dsh-base","@deepseek-ai/dsh-web-app","dynamic-bundle"]}}}"#)
            try write(nestedProfile, "node_modules/dynamic-bundle/package.json", #"{"name":"dynamic-bundle","dsh":{"bundle":{"patch":"./cordis.patch.yml"}}}"#)
            try write(nestedProfile, "node_modules/dynamic-bundle/cordis.patch.yml", """
            - insert:
                - id: dynamic-row
                  name: dynamic-bundle
                  disabled: !!js "Boolean(process.env.DSH_DYNAMIC_DISABLED)"
            """)
            try write(realDshPackage, "package.json", #"{"name":"@deepseek-ai/dsh","version":"1.0.0"}"#)
            try write(virtualPackageRoot, "@deepseek-ai/dsh-base/package.json", #"{"name":"@deepseek-ai/dsh-base","dsh":{"bundle":{}}}"#)
            try write(virtualPackageRoot, "@deepseek-ai/dsh-web-app/package.json", #"{"name":"@deepseek-ai/dsh-web-app","dsh":{"bundle":{}}}"#)
            let linkedDshPackage = nestedRuntime
                .appendingPathComponent("node_modules/@deepseek-ai/dsh", isDirectory: true)
            try fileManager.createDirectory(
                at: linkedDshPackage.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createSymbolicLink(at: linkedDshPackage, withDestinationURL: realDshPackage)
            let nestedParser = nestedRuntime.appendingPathComponent("node_modules/js-yaml", isDirectory: true)
            try fileManager.createDirectory(at: nestedParser.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(
                at: trustedRuntime.appendingPathComponent("node_modules/js-yaml").resolvingSymlinksInPath(),
                to: nestedParser
            )
            let nestedResult = DshPluginInspector(
                profileDirectory: nestedProfile,
                runtime: DshPluginInspectorRuntimeDescriptor(
                    root: nestedRuntime, nodeBinary: trustedNode, integrityVerified: true
                )
            ).inspect()
            require(nestedResult.isComplete, "pnpm nested Runtime and dynamic disabled expression should inspect")
            require(item(nestedResult, "@deepseek-ai/dsh-base").source == .runtimeHost,
                    "base Bundle should resolve from managed pnpm virtual store")
            require(item(nestedResult, "@deepseek-ai/dsh-web-app").source == .runtimeHost,
                    "web Bundle should resolve from managed pnpm virtual store")
            require(item(nestedResult, "dynamic-bundle").status == .healthy,
                    "inert dynamic disabled expression must remain a valid Bundle patch")
            require(!nestedResult.issues.contains { $0.code == "bundlePackageMissing" || $0.code == "patchInvalid" },
                    "valid managed Runtime Bundle and !!js patch must not block startup")

            // pnpm split virtual stores mirror the managed Runtime regression
            // behind the rc.1 startup block: a Bundle resolved through the
            // top-level dsh link references siblings that only exist beside
            // that Bundle's real location, and a later Bundle patch refines
            // an earlier row with the same id. Both must resolve without
            // blocking startup.
            let split = root.appendingPathComponent("split-store", isDirectory: true)
            let splitProfile = split.appendingPathComponent("profile", isDirectory: true)
            let splitRuntime = split.appendingPathComponent("runtime", isDirectory: true)
            let splitDshStore = splitRuntime
                .appendingPathComponent("node_modules/.pnpm/dsh-pkg/node_modules", isDirectory: true)
            let splitBaseStore = splitRuntime
                .appendingPathComponent("node_modules/.pnpm/base-pkg/node_modules", isDirectory: true)
            let realSplitDsh = splitDshStore
                .appendingPathComponent("@deepseek-ai/dsh", isDirectory: true)
            let realSplitBase = splitBaseStore
                .appendingPathComponent("@deepseek-ai/split-base", isDirectory: true)
            try write(splitProfile, "package.json", #"{"name":"dsh-split","private":true,"dependencies":{},"dsh":{"profile":{"bundles":["@deepseek-ai/split-base"]}}}"#)
            try write(splitProfile, "cordis.patch.yml", """
            - id: shared-row
              name: '@deepseek-ai/split-base'
            """)
            try write(realSplitDsh, "package.json", #"{"name":"@deepseek-ai/dsh","version":"1.0.0"}"#)
            try write(realSplitBase, "package.json", #"{"name":"@deepseek-ai/split-base","version":"1.0.0","dsh":{"bundle":{"patch":"./cordis.patch.yml"}}}"#)
            try write(realSplitBase, "cordis.patch.yml", """
            - id: shared-row
              name: '@deepseek-ai/split-base'
            - id: split-leaf-row
              name: '@deepseek-ai/split-leaf'
            """)
            try write(splitBaseStore, "@deepseek-ai/split-leaf/package.json", #"{"name":"@deepseek-ai/split-leaf","version":"1.0.0"}"#)
            let linkedSplitDsh = splitRuntime
                .appendingPathComponent("node_modules/@deepseek-ai/dsh", isDirectory: true)
            try fileManager.createDirectory(
                at: linkedSplitDsh.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createSymbolicLink(at: linkedSplitDsh, withDestinationURL: realSplitDsh)
            let linkedSplitBase = splitDshStore
                .appendingPathComponent("@deepseek-ai/split-base", isDirectory: true)
            try fileManager.createDirectory(
                at: linkedSplitBase.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createSymbolicLink(at: linkedSplitBase, withDestinationURL: realSplitBase)
            let splitParser = splitRuntime.appendingPathComponent("node_modules/js-yaml", isDirectory: true)
            try fileManager.createDirectory(at: splitParser.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(
                at: trustedRuntime.appendingPathComponent("node_modules/js-yaml").resolvingSymlinksInPath(),
                to: splitParser
            )
            let splitResult = DshPluginInspector(
                profileDirectory: splitProfile,
                runtime: DshPluginInspectorRuntimeDescriptor(
                    root: splitRuntime, nodeBinary: trustedNode, integrityVerified: true
                )
            ).inspect()
            require(splitResult.isComplete, "split virtual stores should inspect: \(splitResult.issues)")
            require(!splitResult.issues.contains { $0.code == "patchReferenceMissing" },
                    "split-store sibling must resolve, not block startup")
            require(!splitResult.issues.contains { $0.code == "patchOverride" },
                    "same id across layered patch files is composition, not an override")
            require(item(splitResult, "@deepseek-ai/split-leaf").status == .healthy,
                    "Runtime-internal patch reference must be healthy")
            require(item(splitResult, "@deepseek-ai/split-base").status == .healthy,
                    "Runtime Bundle composed via dsh.profile.bundles must be healthy")

            let invalidReference = root.appendingPathComponent("invalid-reference", isDirectory: true)
            let invalidReferenceProfile = invalidReference.appendingPathComponent("profile", isDirectory: true)
            try write(invalidReferenceProfile, "package.json", #"{"name":"dsh-invalid-reference","dependencies":{"reference-bundle":"1.0.0"},"dsh":{"profile":{"bundles":["reference-bundle"]}}}"#)
            try write(invalidReferenceProfile, "node_modules/reference-bundle/package.json", #"{"name":"reference-bundle","dsh":{"bundle":{}}}"#)
            try write(invalidReferenceProfile, "cordis.patch.yml", "- id: missing-row\n  name: missing-bundle\n")
            let invalidReferenceResult = DshPluginInspector(
                profileDirectory: invalidReferenceProfile,
                runtime: DshPluginInspectorRuntimeDescriptor(
                    root: trustedRuntime, nodeBinary: trustedNode, integrityVerified: true)
            ).inspect()
            require(invalidReferenceResult.issues.contains { $0.code == "patchReferenceMissing" }, "invalid patch reference issue")
            require(item(invalidReferenceResult, "missing-bundle").status == .patchReferenceMissing, "invalid patch reference status")
        }

        print("swift plugin inspector harness passed")
    }
}
