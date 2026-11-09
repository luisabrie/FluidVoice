import Foundation

/// Chat models an account can call through Converse in a region (ListFoundationModels and ListInferenceProfiles).
nonisolated enum BedrockModelCatalog {
    struct ListingError: LocalizedError {
        let statusCode: Int
        let body: String

        var errorDescription: String? {
            "Bedrock model listing HTTP \(self.statusCode): \(self.body.prefix(300))"
        }
    }

    /// Where a model takes a reasoning effort level in `additionalModelRequestFields`: `reasoning_config` for
    /// GPT-5.4 and later, `output_config.effort` for Claude 5.5. Read from the `converse.additionalRequestFieldsSchema`
    /// that ListFoundationModels publishes. Only effort enums are used: Claude 4.5 lists a `reasoningConfig` toggle
    /// there but rejects it.
    struct EffortField: Equatable, Sendable {
        static let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

        let path: [String]
        let levels: [String]

        init(path: [String], levels: [String]) {
            self.path = path
            self.levels = levels
        }

        init?(schemaJSON: String) {
            guard let data = schemaJSON.data(using: .utf8),
                  let schema = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }
            let match = schema.keys.sorted().lazy.compactMap { key -> (path: [String], levels: [String])? in
                guard let spec = schema[key] as? [String: Any] else { return nil }
                let levels = Self.levels(spec)
                if key.lowercased().contains("reasoning"), !levels.isEmpty {
                    return ([key], levels)
                }
                let effortLevels = Self.levels(spec["effort"] as? [String: Any] ?? [:])
                if !effortLevels.isEmpty {
                    return ([key, "effort"], effortLevels)
                }
                return nil
            }.first
            guard let match else { return nil }
            self.init(path: match.path, levels: match.levels)
        }

        /// The requested level if the model takes it, else the next one up, else its highest.
        func level(for requested: String) -> String {
            let requested = requested.lowercased()
            if self.levels.contains(requested) {
                return requested
            }
            guard let rank = Self.order.firstIndex(of: requested) else { return requested }
            return Self.order[rank...].first(where: self.levels.contains)
                ?? Self.order.last(where: self.levels.contains)
                ?? requested
        }

        func set(_ level: String, in fields: inout [String: Any]) {
            guard let key = self.path.first else { return }
            if self.path.count == 1 {
                fields[key] = level
            } else {
                var nested = fields[key] as? [String: Any] ?? [:]
                nested[self.path[1]] = level
                fields[key] = nested
            }
        }

        /// The values of an enum spec; empty for any other spec.
        private static func levels(_ spec: [String: Any]) -> [String] {
            spec["type"] as? String == "enum" ? spec["enum"] as? [String] ?? [] : []
        }
    }

    static func chatModelIDs(region: String, credential: BedrockCredential) async throws -> [String] {
        async let models = self.list("foundation-models?byOutputModality=TEXT", region: region, credential: credential)
        async let profiles = self.list("inference-profiles?maxResults=1000&type=SYSTEM_DEFINED", region: region, credential: credential)
        let foundationModels = try await self.json(models)
        await self.effortFieldCache.store(self.effortFields(foundationModels: foundationModels), region: region)
        return try await self.chatModelIDs(foundationModels: foundationModels, inferenceProfiles: self.json(profiles))
    }

    /// The model's effort field, from the region's model list. The list is fetched once per launch, before a request,
    /// so the lookup gets a short timeout and a failed one waits a few minutes before it's tried again.
    static func effortField(model: String, region: String, credential: BedrockCredential) async -> EffortField? {
        if await self.effortFieldCache.needsLoad(region: region) {
            guard let data = try? await self.list("foundation-models?byOutputModality=TEXT", region: region, credential: credential, timeout: 5),
                  let json = try? self.json(data)
            else {
                await self.effortFieldCache.recordFailure(region: region)
                return nil
            }
            await self.effortFieldCache.store(self.effortFields(foundationModels: json), region: region)
        }
        return await self.effortFieldCache.field(model: model, region: region)
    }

    static func effortFields(foundationModels: [String: Any]) -> [String: EffortField] {
        var fields: [String: EffortField] = [:]
        for model in foundationModels["modelSummaries"] as? [[String: Any]] ?? [] {
            guard let id = model["modelId"] as? String,
                  let schema = (model["converse"] as? [String: Any])?["additionalRequestFieldsSchema"] as? String,
                  let field = EffortField(schemaJSON: schema)
            else { continue }
            fields[id] = field
        }
        return fields
    }

    /// Lets tests supply a region's fields without a network call.
    static func cacheEffortFields(_ fields: [String: EffortField], region: String) async {
        await self.effortFieldCache.store(fields, region: region)
    }

    private actor EffortFieldCache {
        private static let retryDelay: TimeInterval = 300

        private var byRegion: [String: [String: EffortField]] = [:]
        private var failedAt: [String: Date] = [:]

        func needsLoad(region: String) -> Bool {
            guard self.byRegion[region] == nil else { return false }
            return self.failedAt[region].map { Date().timeIntervalSince($0) > Self.retryDelay } ?? true
        }

        func store(_ fields: [String: EffortField], region: String) {
            self.byRegion[region] = fields
            self.failedAt[region] = nil
        }

        func recordFailure(region: String) {
            self.failedAt[region] = Date()
        }

        func field(model: String, region: String) -> EffortField? {
            let fields = self.byRegion[region] ?? [:]
            return fields[model] ?? fields[AmazonBedrock.foundationModelID(model)]
        }
    }

    private static let effortFieldCache = EffortFieldCache()

    /// Active text models with sync and streaming Converse: on-demand ones by model ID, the rest through their
    /// inference profiles.
    static func chatModelIDs(foundationModels: [String: Any], inferenceProfiles: [String: Any]) -> [String] {
        var onDemand: [String] = []
        var needsProfile = Set<String>()
        for model in foundationModels["modelSummaries"] as? [[String: Any]] ?? [] {
            guard let id = model["modelId"] as? String,
                  (model["modelLifecycle"] as? [String: Any])?["status"] as? String == "ACTIVE",
                  (model["inputModalities"] as? [String] ?? []).contains("TEXT"),
                  let converse = (model["inferenceAPIsSupported"] as? [String: Any])?["converse"] as? [String: Any],
                  converse["sync"] as? Bool == true,
                  converse["streaming"] as? Bool == true
            else { continue }
            let types = model["inferenceTypesSupported"] as? [String] ?? []
            if types.contains("ON_DEMAND") {
                onDemand.append(id)
            } else if types.contains("INFERENCE_PROFILE") {
                needsProfile.insert(id)
            }
        }

        let profiles = (inferenceProfiles["inferenceProfileSummaries"] as? [[String: Any]] ?? []).compactMap { profile -> String? in
            guard let id = profile["inferenceProfileId"] as? String,
                  (profile["status"] as? String ?? "ACTIVE") == "ACTIVE",
                  let models = profile["models"] as? [[String: Any]],
                  models.contains(where: { needsProfile.contains(($0["modelArn"] as? String)?.split(separator: "/").last.map(String.init) ?? "") })
            else { return nil }
            return id
        }
        return Array(Set(onDemand + profiles)).sorted()
    }

    private static func list(_ pathAndQuery: String, region: String, credential: BedrockCredential, timeout: TimeInterval = 15) async throws -> Data {
        guard let url = URL(string: "https://bedrock.\(region).amazonaws.com/\(pathAndQuery)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        switch credential {
        case let .profile(profile):
            let credentials = try await AWSCLICredentialProvider.shared.credentials(profile: profile)
            AWSSigV4.sign(&request, credentials: credentials, region: region, service: "bedrock")
        case let .apiKey(key):
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ListingError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return json
    }
}
