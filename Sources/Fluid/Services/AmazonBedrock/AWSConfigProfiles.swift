import Foundation

/// Profiles from the shared AWS config and credentials files.
nonisolated enum AWSConfigProfiles {
    struct Profile: Equatable, Sendable {
        let name: String
        let usesSSO: Bool
    }

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> [Profile] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configPath = environment["AWS_CONFIG_FILE"] ?? "\(home)/.aws/config"
        let credentialsPath = environment["AWS_SHARED_CREDENTIALS_FILE"] ?? "\(home)/.aws/credentials"
        return self.parse(
            config: (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? "",
            credentials: (try? String(contentsOfFile: credentialsPath, encoding: .utf8)) ?? ""
        )
    }

    static func parse(config: String, credentials: String) -> [Profile] {
        var settings: [String: [String: String]] = [:]
        var order: [String] = []

        func read(_ text: String, sectionName: (String) -> String?) {
            var current: String?
            for rawLine in text.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                    continue
                }
                if line.hasPrefix("["), line.hasSuffix("]") {
                    current = sectionName(String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces))
                    if let current, settings[current] == nil {
                        settings[current] = [:]
                        order.append(current)
                    }
                    continue
                }
                guard let current, let separator = line.firstIndex(of: "=") else { continue }
                let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
                settings[current]?[key] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            }
        }

        read(config) { header in
            if header == "default" {
                return "default"
            }
            // Skips sso-session and services sections.
            guard header.hasPrefix("profile ") else { return nil }
            let name = header.dropFirst("profile ".count).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        read(credentials) { $0.isEmpty ? nil : $0 }

        return order.map { name in
            let values = settings[name] ?? [:]
            return Profile(name: name, usesSSO: values["sso_session"] != nil || values["sso_start_url"] != nil)
        }
    }
}
