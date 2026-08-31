import Foundation

/// Redacts credentials before they enter process diagnostics. It deliberately
/// combines known secrets with protocol-shaped matching so a token printed
/// before registration, in a Set-Cookie header, or through a different log
/// path is still removed.
public struct DshSecretRedactor: Sendable {
    public static let replacement = "[REDACTED]"

    private let secrets: [String]

    private static let queryCredentialRegex = try! NSRegularExpression(
        pattern: #"(?i)([?&](?:token|dsh-auth(?:-[A-Za-z0-9_-]+)?)(?:=|%3d))[^&#\s]*"#
    )
    private static let authorizationRegex = try! NSRegularExpression(
        pattern: #"(?i)((?:authorization\s*:\s*|authorization\s+)(?:(?:bearer|basic)\s+)?)[^\s,;]+"#
    )
    private static let cookieValueRegex = try! NSRegularExpression(
        pattern: #"(?i)((?:cookie|set-cookie)\s*:\s*[^=;\r\n]+=|;\s*[^=;\r\n]+=)[^;\r\n]*"#
    )
    private static let tokenShapeRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])"#
    )
    private static let ansiRegex = try! NSRegularExpression(
        pattern: #"\u001B(?:\[[0-?]*[ -/]*[@-~]|\][^\u0007]*(?:\u0007|\u001B\\))"#
    )

    public init(secrets: [String] = []) {
        self.secrets = secrets
            .filter { !$0.isEmpty }
            .reduce(into: []) { result, value in
                if !result.contains(value) { result.append(value) }
            }
    }

    public func redact(_ text: String) -> String {
        var output = Self.stripANSI(text)

        // Replace the literal and one/two percent-encoded forms before the
        // shape matcher. The latter covers tokens that contain URL-reserved
        // bytes in diagnostic fixtures without decoding the complete log.
        for secret in secrets {
            let encoded = Self.percentEncode(secret)
            let doubleEncoded = Self.percentEncode(encoded)
            for candidate in [secret, encoded, doubleEncoded] where !candidate.isEmpty {
                output = output.replacingOccurrences(of: candidate, with: Self.replacement)
            }
        }

        output = Self.replace(output, regex: Self.queryCredentialRegex, template: "$1\(Self.replacement)")
        output = Self.replace(output, regex: Self.authorizationRegex, template: "$1\(Self.replacement)")

        let lowercased = output.lowercased()
        if lowercased.contains("cookie:") || lowercased.contains("set-cookie:") {
            output = Self.replace(output, regex: Self.cookieValueRegex, template: "$1\(Self.replacement)")
        }

        return Self.replace(output, regex: Self.tokenShapeRegex, template: Self.replacement)
    }

    public static func stripANSI(_ text: String) -> String {
        replace(text, regex: ansiRegex, template: "")
    }

    private static func replace(_ text: String, regex: NSRegularExpression, template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    private static func percentEncode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
