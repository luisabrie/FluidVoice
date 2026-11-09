import Foundation

// MARK: - Endpoint

/// Recognizes Bedrock's runtime endpoint (`https://bedrock-runtime.{region}.amazonaws.com`), which serves every
/// chat model through the Converse API. Default URLs and models live in `ModelRepository`.
nonisolated enum AmazonBedrock {
    static let providerID = "bedrock"
    static let displayName = "Amazon Bedrock"
    static let defaultRegion = "us-east-1"

    /// The runtime root, including VPC endpoint hosts. Its `/openai/v1` route keeps using Chat Completions.
    static func isConverseEndpoint(baseURL: String) -> Bool {
        guard let url = self.url(baseURL), let host = url.host else { return false }
        return self.isRuntimeHost(host) && ["", "/"].contains(url.path)
    }

    static func isRuntimeHost(_ host: String) -> Bool {
        host.lowercased().split(separator: ".").contains("bedrock-runtime")
    }

    /// The label after `bedrock-runtime` in the host.
    static func region(fromBaseURL baseURL: String) -> String? {
        guard let labels = self.url(baseURL)?.host?.lowercased().split(separator: "."),
              let index = labels.firstIndex(of: "bedrock-runtime"),
              index + 1 < labels.count
        else { return nil }
        return self.normalizedRegion(String(labels[index + 1]))
    }

    /// Accepts only region-shaped values, so a stored region can never change the request host.
    static func normalizedRegion(_ value: String) -> String? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard candidate.range(of: #"^[a-z]{2,4}(-[a-z]+)+-[0-9]{1,2}$"#, options: .regularExpression) != nil else { return nil }
        return candidate
    }

    /// Bedrock uses the usual API Key field only when signing in with a Bedrock API key.
    static func showsAPIKeyField(providerID: String, credential: String) -> Bool {
        providerID != self.providerID || !BedrockCredential(storedValue: credential).usesProfile
    }

    /// The model behind an inference profile: `us.anthropic.claude-…` and `global.anthropic.claude-…` both give
    /// `anthropic.claude-…`. Other IDs come back unchanged.
    static func foundationModelID(_ modelID: String) -> String {
        guard let dot = modelID.firstIndex(of: "."), self.profilePrefixes.contains(String(modelID[..<dot])) else { return modelID }
        return String(modelID[modelID.index(after: dot)...])
    }

    /// A 401, or a 403 about the security token or signature. A role that may not use a model also gets a 403
    /// (AccessDeniedException), but its credentials are fine.
    static func rejectsCredentials(status: Int, body: String) -> Bool {
        let body = body.lowercased()
        return status == 401 || (status == 403 && (body.contains("token") || body.contains("signature")))
    }

    private static let profilePrefixes: Set = ["us", "us-gov", "eu", "apac", "jp", "au", "in", "global"]

    private static func url(_ baseURL: String) -> URL? {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Credential

/// Bedrock's API key slot holds an AWS profile reference or a Bedrock API key, so the existing key checks and
/// verification fingerprints work unchanged. A profile reference never leaves the Mac.
nonisolated enum BedrockCredential: Equatable {
    case profile(String)
    case apiKey(String)

    static let profilePrefix = "aws-profile:"

    init(storedValue: String) {
        let trimmed = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(Self.profilePrefix) {
            self = .profile(String(trimmed.dropFirst(Self.profilePrefix.count)).trimmingCharacters(in: .whitespaces))
        } else {
            self = .apiKey(trimmed)
        }
    }

    var storedValue: String {
        switch self {
        case let .profile(name): return Self.profilePrefix + name
        case let .apiKey(key): return key
        }
    }

    var usesProfile: Bool {
        if case .profile = self {
            return true
        }
        return false
    }

    var profileName: String? {
        if case let .profile(name) = self, !name.isEmpty {
            return name
        }
        return nil
    }

    var isComplete: Bool {
        switch self {
        case let .profile(name): return !name.isEmpty
        case let .apiKey(key): return !key.isEmpty
        }
    }
}
