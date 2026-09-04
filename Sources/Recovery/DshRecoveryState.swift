import Foundation

/// Persisted phases for one app-owned recovery Profile. The record is small
/// by design: it identifies what may be cleaned and how to reconstruct a
/// recovery launch, without embedding a copy of a normal Profile.
public enum DshRecoveryPhase: String, Codable, Equatable, Hashable, Sendable {
    case entered
    case launched
    case returned
    case cleanupPending
    case cleaned
}

/// `enterRecovery` only creates the app-owned seed and durable ownership
/// record. Runtime package materialization is an outer coordinator concern;
/// it must explicitly move this value to `prepared` before launch.
public enum DshRecoveryPreparation: String, Codable, Equatable, Hashable, Sendable {
    case requiresPreparation
    case prepared
}

/// Where a package used by the recovery launch is expected to be materialized.
/// The Runtime's base/web packages are owned by the managed Runtime install;
/// only the desktop bridge and its matching webserver are materialized into
/// the app-owned recovery Profile.
public enum DshRecoveryPackageProofSource: String, Codable, Equatable, Sendable {
    case managedRuntime
    case recoveryProfile
}

/// A package manifest that the launch coordinator observed after materializing
/// the recovery Profile. The manager re-reads this exact path and verifies the
/// name and version before accepting the preparation proof.
public struct DshRecoveryPackageProof: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let manifestRelativePath: String
    public let source: DshRecoveryPackageProofSource

    public init(
        name: String,
        version: String,
        manifestRelativePath: String,
        source: DshRecoveryPackageProofSource = .recoveryProfile
    ) {
        self.name = name
        self.version = version
        self.manifestRelativePath = manifestRelativePath
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case version
        case manifestRelativePath
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.version = try container.decode(String.self, forKey: .version)
        self.manifestRelativePath = try container.decode(String.self, forKey: .manifestRelativePath)
        self.source = try container.decodeIfPresent(
            DshRecoveryPackageProofSource.self,
            forKey: .source
        ) ?? .recoveryProfile
    }
}

/// Exact bytes and a digest for the bridge manifest supplied by the
/// coordinator. Keeping both values in the proof prevents a name-only or
/// directory-shape check from turning a partial or modified install into a
/// launchable recovery Profile.
public struct DshRecoveryBridgeProof: Codable, Equatable, Sendable {
    public let manifestRelativePath: String
    public let fingerprint: String
    public let manifestBytes: Data

    public init(
        manifestRelativePath: String,
        fingerprint: String,
        manifestBytes: Data
    ) {
        self.manifestRelativePath = manifestRelativePath
        self.fingerprint = fingerprint
        self.manifestBytes = manifestBytes
    }
}

/// Coordinator-supplied evidence that all official recovery packages and the
/// app bridge were installed. This value is persisted with `.prepared`, so a
/// process interruption can resume from the durable proof instead of
/// silently trusting a directory that only happens to exist.
public struct DshRecoveryPreparationProof: Codable, Equatable, Sendable {
    public let runtimeVersion: String
    public let packageManifests: [DshRecoveryPackageProof]
    public let bridge: DshRecoveryBridgeProof

    public init(
        runtimeVersion: String,
        packageManifests: [DshRecoveryPackageProof],
        bridge: DshRecoveryBridgeProof
    ) {
        self.runtimeVersion = runtimeVersion
        self.packageManifests = packageManifests
        self.bridge = bridge
    }
}

public struct DshRecoveryState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let recoveryID: UUID
    public let recoveryProfileName: String
    public let originalProfile: DshAppProfile
    /// The original home is recorded for an explicit data bridge decision;
    /// it is never used as the recovery process's DSH_HOME.
    public let originalDshHome: URL?
    public let runtimeDescriptor: NpmRuntimeDescriptor
    public let transactionID: String?
    public let port: Int
    /// Marker for the manager-generated home overlay. It lets cleanup prove
    /// that an existing `cordis.patch.yml` belongs to this recovery record;
    /// older records may omit it because they never generated an overlay.
    public let homePatchOwnershipMarker: String?
    public var preparation: DshRecoveryPreparation
    /// Non-nil only after the coordinator's package and bridge evidence has
    /// been checked and durably committed by `markPrepared`.
    public var preparationProof: DshRecoveryPreparationProof?
    public var phase: DshRecoveryPhase

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case recoveryID
        case recoveryProfileName
        case originalProfile
        case originalDshHome
        case runtimeDescriptor
        case transactionID
        case port
        case homePatchOwnershipMarker
        case preparation
        case preparationProof
        case phase
    }

    public init(
        schemaVersion: Int = DshRecoveryState.currentSchemaVersion,
        recoveryID: UUID,
        recoveryProfileName: String,
        originalProfile: DshAppProfile,
        originalDshHome: URL?,
        runtimeDescriptor: NpmRuntimeDescriptor,
        transactionID: String?,
        port: Int,
        homePatchOwnershipMarker: String? = nil,
        preparation: DshRecoveryPreparation = .requiresPreparation,
        preparationProof: DshRecoveryPreparationProof? = nil,
        phase: DshRecoveryPhase
    ) {
        self.schemaVersion = schemaVersion
        self.recoveryID = recoveryID
        self.recoveryProfileName = recoveryProfileName
        self.originalProfile = originalProfile
        self.originalDshHome = originalDshHome
        self.runtimeDescriptor = runtimeDescriptor
        self.transactionID = transactionID
        self.port = port
        self.homePatchOwnershipMarker = homePatchOwnershipMarker
        self.preparation = preparation
        self.preparationProof = preparationProof
        self.phase = phase
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.recoveryID = try container.decode(UUID.self, forKey: .recoveryID)
        self.recoveryProfileName = try container.decode(String.self, forKey: .recoveryProfileName)
        self.originalProfile = try container.decode(DshAppProfile.self, forKey: .originalProfile)
        self.originalDshHome = try container.decodeIfPresent(URL.self, forKey: .originalDshHome)
        self.runtimeDescriptor = try container.decode(NpmRuntimeDescriptor.self, forKey: .runtimeDescriptor)
        self.transactionID = try container.decodeIfPresent(String.self, forKey: .transactionID)
        self.port = try container.decode(Int.self, forKey: .port)
        self.homePatchOwnershipMarker = try container.decodeIfPresent(
            String.self,
            forKey: .homePatchOwnershipMarker
        )
        // State files created before the materialization gate are resumed as
        // requiring preparation; decoding them must never assume they are
        // launchable merely because the old phase was `entered`.
        self.preparation = try container.decodeIfPresent(
            DshRecoveryPreparation.self,
            forKey: .preparation
        ) ?? .requiresPreparation
        self.preparationProof = try container.decodeIfPresent(
            DshRecoveryPreparationProof.self,
            forKey: .preparationProof
        )
        self.phase = try container.decode(DshRecoveryPhase.self, forKey: .phase)
    }
}

public enum DshRecoveryStateReadResult: Equatable, Sendable {
    case absent
    case loaded(DshRecoveryState)
    case corrupted(String)
}
