import Foundation

/// Redacts credentials before they enter process diagnostics. It deliberately
/// combines known secrets with protocol-shaped matching so a token printed
/// before registration, in a Set-Cookie header, or through a different log
/// path is still removed.
public struct DshSecretRedactor: Sendable {
    public static let replacement = "[REDACTED]"

    private let secrets: [String]

    // These names are deliberately treated as sensitive only when they are
    // used as an assignment key. This keeps ordinary text such as
    // "token is invalid" readable while covering short values that cannot be
    // identified by a protocol-shaped token matcher.
    private static let sensitiveAssignmentKeys = [
        "authorization", "client_secret", "refresh_token", "access_token",
        "session_token", "auth_token", "x-api-key", "api-key", "set-cookie",
        "password", "api_key", "apikey", "cookie", "secret", "token"
    ]

    private static let queryCredentialRegex = try! NSRegularExpression(
        pattern: #"(?i)([?&](?:token|dsh-auth(?:-[A-Za-z0-9_-]+)?)(?:=|%3d))[^&#\s]*"#
    )
    private static let authorizationRegex = try! NSRegularExpression(
        pattern: #"(?i)((?:authorization\s*:\s*(?:(?:bearer|basic)\s+)?|authorization\s+(?:bearer|basic)\s+))[^\s,;]+"#
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

    /// Applies the complete diagnostic boundary policy: known/protocol-shaped
    /// credentials, explicitly named credential fields, and user home paths.
    /// Export previews and recovery details use this same method so a value
    /// cannot reappear merely by taking a different presentation path.
    public func redactDiagnostic(_ text: String, pathPrefixes: [String] = []) -> String {
        var output = redact(text)
        output = redactSensitiveAssignments(output)

        let prefixes = pathPrefixes + [FileManager.default.homeDirectoryForCurrentUser.path]
        for prefix in prefixes where !prefix.isEmpty {
            output = output.replacingOccurrences(of: prefix, with: "[USER_HOME]")
        }
        output = replaceGenericUserPaths(output, root: "/Users/")
        output = replaceGenericUserPaths(output, root: "/home/")
        return output
    }

    /// Redacts values from JSON and JSON-like key/value text. Quoted values
    /// are consumed as a whole, including short values such as "abc" and
    /// cookie strings containing their own `=` character.
    public func redactSensitiveAssignments(_ text: String) -> String {
        var output = ""
        var index = text.startIndex

        while index < text.endIndex {
            guard let keyEnd = sensitiveKeyEnd(at: index, in: text) else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }

            var cursor = keyEnd
            // JSON object keys are quoted ("token":"..."), while
            // JSON-like logs commonly omit those quotes. Accept the closing
            // key quote before looking for the assignment delimiter.
            if cursor < text.endIndex, text[cursor] == "\"" || text[cursor] == "'" {
                cursor = text.index(after: cursor)
            }
            while cursor < text.endIndex, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex, text[cursor] == ":" || text[cursor] == "=" else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }

            // Keep the key, spacing, and assignment delimiter exactly as
            // written; only the value is replaced.
            output.append(contentsOf: text[index...cursor])
            let afterDelimiter = text.index(after: cursor)
            var valueStart = afterDelimiter
            while valueStart < text.endIndex, text[valueStart].isWhitespace {
                valueStart = text.index(after: valueStart)
            }
            output.append(contentsOf: text[afterDelimiter..<valueStart])

            guard valueStart < text.endIndex else {
                index = valueStart
                continue
            }

            let first = text[valueStart]
            if first == "\"" || first == "'" {
                output.append(first)
                var scan = text.index(after: valueStart)
                var escaped = false
                var closed = false
                while scan < text.endIndex {
                    let character = text[scan]
                    if character == first, !escaped {
                        output.append(Self.replacement)
                        output.append(character)
                        scan = text.index(after: scan)
                        closed = true
                        break
                    }
                    if character == "\\", !escaped {
                        escaped = true
                    } else {
                        escaped = false
                    }
                    scan = text.index(after: scan)
                }
                if !closed {
                    output.append(Self.replacement)
                    scan = text.endIndex
                }
                index = scan
                continue
            }

            if first == "{" || first == "[" {
                let scan = endOfStructuredValue(startingAt: valueStart, in: text)
                output.append("\"\(Self.replacement)\"")
                index = scan
                continue
            }

            var valueEnd = valueStart
            while valueEnd < text.endIndex {
                let character = text[valueEnd]
                if ",;&\r\n}]".contains(character) {
                    break
                }
                valueEnd = text.index(after: valueEnd)
            }
            if valueStart < valueEnd {
                output.append(Self.replacement)
            }
            index = valueEnd
        }

        return output
    }

    public static func stripANSI(_ text: String) -> String {
        replace(text, regex: ansiRegex, template: "")
    }

    private func sensitiveKeyEnd(at index: String.Index, in text: String) -> String.Index? {
        if index > text.startIndex {
            let previous = text[text.index(before: index)]
            if Self.isAssignmentKeyCharacter(previous) { return nil }
        }

        for key in Self.sensitiveAssignmentKeys {
            guard let end = text.index(index, offsetBy: key.count, limitedBy: text.endIndex),
                  String(text[index..<end]).lowercased() == key else {
                continue
            }
            if end < text.endIndex, Self.isAssignmentKeyCharacter(text[end]) {
                continue
            }
            return end
        }
        return nil
    }

    private static func isAssignmentKeyCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }

    private func endOfStructuredValue(startingAt start: String.Index, in text: String) -> String.Index {
        var stack: [Character] = [text[start]]
        var scan = text.index(after: start)
        var quote: Character?
        var escaped = false

        while scan < text.endIndex {
            let character = text[scan]
            if let activeQuote = quote {
                if character == activeQuote, !escaped {
                    quote = nil
                }
                escaped = character == "\\" && !escaped
                if character != "\\" { escaped = false }
                scan = text.index(after: scan)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "{" || character == "[" {
                stack.append(character)
            } else if character == "}" || character == "]" {
                if !stack.isEmpty { stack.removeLast() }
                scan = text.index(after: scan)
                if stack.isEmpty { return scan }
                continue
            }
            scan = text.index(after: scan)
        }
        return scan
    }

    private func replaceGenericUserPaths(_ value: String, root: String) -> String {
        var output = value
        var searchStart = output.startIndex
        while let rootRange = output.range(of: root, range: searchStart..<output.endIndex) {
            let usernameStart = rootRange.upperBound
            guard let usernameEnd = output[usernameStart...].firstIndex(of: "/") else {
                guard usernameStart < output.endIndex else { break }
                output.replaceSubrange(rootRange.lowerBound..<output.endIndex, with: "[USER_HOME]")
                break
            }
            var pathEnd = usernameEnd
            while pathEnd < output.endIndex {
                let character = output[pathEnd]
                if character.isWhitespace || "\"'<>[]{}(),;".contains(character) { break }
                pathEnd = output.index(after: pathEnd)
            }
            let suffix = String(output[usernameEnd..<pathEnd])
            output.replaceSubrange(rootRange.lowerBound..<pathEnd, with: "[USER_HOME]" + suffix)
            searchStart = output.index(rootRange.lowerBound, offsetBy: "[USER_HOME]".count + suffix.count)
        }
        return output
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
