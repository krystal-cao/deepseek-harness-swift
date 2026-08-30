import Foundation

/// A SemVer 2.0.0 value used for ordering DSH releases.
///
/// The runtime manager still applies its own product policy and currently
/// allows only stable and `rc.N` releases. Keeping the parser complete means
/// version ordering will not need to change when the policy is widened later.
public struct DshSemanticVersion: Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]
    public let buildMetadata: [String]

    private let prereleaseIsNumeric: [Bool]

    public init?(_ value: String) {
        let version = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return nil }

        let buildParts = version.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        let withoutBuild = String(buildParts[0])
        let buildMetadata = buildParts.count == 2
            ? buildParts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : []
        guard buildMetadata.allSatisfy(Self.isValidIdentifier) else { return nil }

        let prereleaseParts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = prereleaseParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              core.allSatisfy(Self.isValidNumericCore) else { return nil }

        let prerelease = prereleaseParts.count == 2
            ? prereleaseParts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : []
        guard prerelease.allSatisfy(Self.isValidIdentifier) else { return nil }

        let numericFlags = prerelease.map { Self.isNumericIdentifier($0) }
        for (identifier, isNumeric) in zip(prerelease, numericFlags) {
            if isNumeric && identifier.count > 1 && identifier.first == "0" { return nil }
        }

        guard let major = Int(core[0]),
              let minor = Int(core[1]),
              let patch = Int(core[2]) else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.buildMetadata = buildMetadata
        self.prereleaseIsNumeric = numericFlags
    }

    public static func < (lhs: DshSemanticVersion, rhs: DshSemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true):
            return false
        case (true, false):
            return false
        case (false, true):
            return true
        case (false, false):
            for index in 0..<min(lhs.prerelease.count, rhs.prerelease.count) {
                let left = lhs.prerelease[index]
                let right = rhs.prerelease[index]
                if left == right { continue }

                let leftNumeric = lhs.prereleaseIsNumeric[index]
                let rightNumeric = rhs.prereleaseIsNumeric[index]
                if leftNumeric && rightNumeric {
                    if left.count != right.count { return left.count < right.count }
                    return left < right
                }
                if leftNumeric != rightNumeric { return leftNumeric }
                return left < right
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }
    }

    public static func == (lhs: DshSemanticVersion, rhs: DshSemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    private static func isValidNumericCore(_ value: Substring) -> Bool {
        guard !value.isEmpty,
              value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return value.count == 1 || value.first != "0"
    }

    private static func isNumericIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy({ $0.isASCII && $0.isNumber })
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { character in
            character.isASCII && (character.isNumber || character.isLetter || character == "-")
        }
    }

    /// `dsh web --no-open` was introduced in 0.1.0-rc.8.
    public var supportsNoOpen: Bool {
        self >= DshSemanticVersion.noOpenMinimum
    }

    private static let noOpenMinimum = DshSemanticVersion("0.1.0-rc.8")!
}
