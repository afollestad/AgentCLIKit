import Foundation

/// A disposable worker must never rotate the refresh token shared by the user's persistent OpenCode profile.
enum OpenCodeOneShotAuthentication {
    /// The OpenAI refresh credential belongs to the persistent login. A late/unauthorized refresh must fail in the disposable copy.
    static func isolatedCopy(_ authentication: JSONValue?) -> JSONValue {
        var providers = authentication?.ocObject ?? [:]
        if var openAI = providers["openai"]?.ocObject, openAI["type"] == .string("oauth") {
            openAI["refresh"] = .string("")
            providers["openai"] = .object(openAI)
        }
        return .object(providers)
    }

    static func validate(_ authentication: JSONValue?, minimumValidity: TimeInterval, now: Date = Date()) throws {
        for (provider, credentials) in authentication?.ocObject ?? [:] where credentials[oc: "type"] == .string("oauth") {
            switch provider {
            case "openai":
                // The bundled Codex plugin refreshes only when access is absent or expires; the launch deadline precedes that boundary.
                guard let access = credentials[oc: "access"]?.ocString, !access.isEmpty,
                      let expiry = credentials[oc: "expires"]?.ocInt,
                      Double(expiry) / 1_000 > now.timeIntervalSince1970 + minimumValidity else {
                    throw AgentCLIError.invalidInput("Refresh the OpenCode OpenAI login before an isolated prompt; its token expires too soon.")
                }
            case "github-copilot":
                // Native Copilot stores its nonrotating bearer in `refresh` and uses expires=0; it does not refresh during inference.
                guard let token = credentials[oc: "refresh"]?.ocString, !token.isEmpty else {
                    throw AgentCLIError.invalidInput("The OpenCode GitHub Copilot login is unavailable for an isolated prompt.")
                }
            default:
                throw AgentCLIError.invalidInput("The selected OpenCode OAuth provider cannot safely isolate its login for a one-shot prompt.")
            }
        }
    }
}
