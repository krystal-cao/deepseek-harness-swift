import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct RuntimeHealthHarness {
    static func main() async {
        guard CommandLine.arguments.count == 3,
              let port = Int(CommandLine.arguments[1]),
              !CommandLine.arguments[2].isEmpty,
              let origin = URL(string: "http://127.0.0.1:\(port)/"),
              let launchURL = URL(string: "http://127.0.0.1:\(port)/?token=fixture-launch-token") else {
            fputs("FAIL: expected fixture port\n", stderr)
            exit(1)
        }

        let client = DshRuntimeHealthClient()
        let rendererOnly = DshRuntimeHealthCredentials(cookieHeader: "dsh_swift_renderer=renderer-token")
        let authenticated = DshRuntimeHealthCredentials(
            cookieHeader: "dsh_swift_renderer=renderer-token; \(CommandLine.arguments[2])=fixture-upstream-cookie"
        )

        do {
            let anonymous = try await client.perform(
                request: URLRequest(url: origin),
                credentials: .anonymous,
                label: "anonymous",
                requireCleanFinalURL: true
            )
            require(anonymous.statusCode == 401, "anonymous alpha page must remain protected")
            require(anonymous.finalURL == origin, "anonymous result must remain on the clean origin")

            let renderer = try await client.perform(
                request: URLRequest(url: origin),
                credentials: rendererOnly,
                label: "renderer-only",
                requireCleanFinalURL: true
            )
            require(renderer.statusCode == 401, "Renderer cookie alone must not satisfy upstream auth")

            let exchange = try await client.perform(
                request: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/__fixture/handoff")!),
                credentials: rendererOnly,
                label: "bootstrap",
                requireCleanFinalURL: true,
                requireCleanRedirectTargets: false
            )
            require(exchange.statusCode == 401, "a health client must not persist the redirect Set-Cookie")
            require(exchange.redirectCount == 2, "handoff and bootstrap redirects must be followed exactly once")
            require(exchange.finalURL == origin, "bootstrap redirect must finish at clean root")
            require(exchange.setCookieHeaders.contains { $0.hasPrefix("dsh-auth-") }, "bootstrap must expose the upstream cookie to the explicit caller")
            require(!String(data: exchange.body, encoding: .utf8)!.contains("fixture-launch-token"), "response body must not echo the launch token")

            let page = try await client.perform(
                request: URLRequest(url: origin),
                credentials: authenticated,
                label: "authenticated",
                requireCleanFinalURL: true
            )
            require(page.statusCode == 200, "explicit Renderer plus upstream cookies must reach the page")
            require(DshRuntimeHealthClient.isHTMLPage(page), "authenticated page must be validated as HTML")

            do {
                _ = try await client.perform(
                    request: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/__fixture/handoff")!),
                    credentials: rendererOnly,
                    label: "bounded-bootstrap",
                    requireCleanFinalURL: true,
                    requireCleanRedirectTargets: false,
                    maxRedirects: 0
                )
                require(false, "redirect limit must be enforced")
            } catch let error as DshRuntimeHealthClient.ClientError {
                if case .tooManyRedirects = error {
                    // Expected.
                } else {
                    require(false, "unexpected redirect-limit error: \(error)")
                }
                require(!error.localizedDescription.contains("fixture-launch-token"), "health errors must not disclose URL secrets")
            }
        } catch {
            fputs("FAIL: runtime health fixture failed: \(error)\n", stderr)
            exit(1)
        }

        print("swift runtime health client harness passed")
    }
}
