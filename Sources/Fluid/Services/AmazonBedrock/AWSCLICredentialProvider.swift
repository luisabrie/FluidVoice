import Foundation

nonisolated enum AWSCLIError: LocalizedError, Equatable {
    case cliNotFound
    case signInRequired(profile: String)
    case profileNotFound(profile: String)
    case commandFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Install AWS CLI v2 to sign in with an AWS profile (brew install awscli)."
        case let .signInRequired(profile):
            return "The AWS sign-in for profile '\(profile)' expired. Sign in again, or run: aws sso login --profile \(profile)"
        case let .profileNotFound(profile):
            return "AWS profile '\(profile)' isn't in ~/.aws/config. Set it up with: aws configure sso"
        case let .commandFailed(message):
            return "AWS CLI: \(message)"
        case .timedOut:
            return "The AWS CLI didn't respond in time."
        }
    }

    static func classify(stderr: String, exitCode: Int32, profile: String) -> AWSCLIError {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = message.lowercased()
        if lower.contains("could not be found"), lower.contains("profile") {
            return .profileNotFound(profile: profile)
        }
        if lower.contains("sso"), ["expired", "sso login", "does not exist", "invalid", "refresh failed"].contains(where: { lower.contains($0) }) {
            return .signInRequired(profile: profile)
        }
        return .commandFailed(message.isEmpty ? "exit code \(exitCode)" : String(message.prefix(400)))
    }
}

nonisolated struct AWSCLIResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

nonisolated protocol AWSCLIRunning: Sendable {
    func run(arguments: [String], timeout: TimeInterval) async throws -> AWSCLIResult
}

/// Resolves AWS profile credentials with `aws configure export-credentials`, so IAM Identity Center (SSO),
/// role chaining, and `credential_process` work as they do in Terminal. Credentials stay in memory.
actor AWSCLICredentialProvider {
    static let shared = AWSCLICredentialProvider()

    /// Refresh this long before the CLI-reported expiration.
    static let refreshMargin: TimeInterval = 5 * 60
    /// Static keys report no expiration; re-read them so profile edits apply.
    static let staticCredentialLifetime: TimeInterval = 15 * 60

    private struct CacheEntry {
        let credentials: AWSCredentials
        let refreshAfter: Date
    }

    private let runner: AWSCLIRunning
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<CacheEntry, Error>] = [:]

    init(runner: AWSCLIRunning = ProcessAWSCLIRunner()) {
        self.runner = runner
    }

    func credentials(profile: String, now: Date = Date()) async throws -> AWSCredentials {
        let cached = self.cache[profile]
        if let cached, cached.refreshAfter > now {
            return cached.credentials
        }
        let refresh = self.inFlight[profile] ?? self.startRefresh(profile: profile, now: now)
        // Credentials that still work are used while the refresh runs, so requests don't wait for the CLI.
        if let cached, cached.credentials.expiration.map({ $0 > now }) ?? true {
            return cached.credentials
        }
        return try await refresh.value.credentials
    }

    /// Runs `aws sso login`, which finishes in the browser.
    func signIn(profile: String) async throws {
        DebugLogger.shared.info("Starting AWS SSO sign-in for profile '\(profile)'", source: "AmazonBedrock")
        let result = try await self.runner.run(arguments: ["sso", "login", "--profile", profile], timeout: 300)
        self.invalidate(profile: profile)
        guard result.exitCode == 0 else {
            let error = AWSCLIError.classify(stderr: result.stderr, exitCode: result.exitCode, profile: profile)
            DebugLogger.shared.warning("AWS SSO sign-in failed for profile '\(profile)': \(error.localizedDescription)", source: "AmazonBedrock")
            throw error
        }
    }

    func invalidate(profile: String) {
        self.cache[profile] = nil
    }

    private func startRefresh(profile: String, now: Date) -> Task<CacheEntry, Error> {
        let runner = self.runner
        let task = Task<CacheEntry, Error> {
            defer { self.inFlight[profile] = nil }
            do {
                let result = try await runner.run(
                    arguments: ["configure", "export-credentials", "--profile", profile, "--format", "process"],
                    timeout: 30
                )
                let credentials = try Self.parseExport(result, profile: profile)
                let refreshAfter = credentials.expiration.map { $0.addingTimeInterval(-Self.refreshMargin) }
                    ?? now.addingTimeInterval(Self.staticCredentialLifetime)
                let entry = CacheEntry(credentials: credentials, refreshAfter: refreshAfter)
                self.cache[profile] = entry
                DebugLogger.shared.debug("Exported AWS credentials for profile '\(profile)'", source: "AmazonBedrock")
                return entry
            } catch {
                DebugLogger.shared.warning("AWS credential export failed for profile '\(profile)': \(error.localizedDescription)", source: "AmazonBedrock")
                throw error
            }
        }
        self.inFlight[profile] = task
        return task
    }

    static func parseExport(_ result: AWSCLIResult, profile: String) throws -> AWSCredentials {
        guard result.exitCode == 0 else {
            throw AWSCLIError.classify(stderr: result.stderr, exitCode: result.exitCode, profile: profile)
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let accessKeyID = json["AccessKeyId"] as? String, !accessKeyID.isEmpty,
              let secretAccessKey = json["SecretAccessKey"] as? String, !secretAccessKey.isEmpty
        else {
            throw AWSCLIError.commandFailed("export-credentials returned no credentials for profile '\(profile)'.")
        }
        return AWSCredentials(
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: json["SessionToken"] as? String,
            expiration: (json["Expiration"] as? String).flatMap(Self.parseDate)
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

// MARK: - Process

/// Runs the AWS CLI like `MediaHelperProcess`: no shell, bounded output, and a deadline, off the main actor.
nonisolated struct ProcessAWSCLIRunner: AWSCLIRunning {
    func run(arguments: [String], timeout: TimeInterval) async throws -> AWSCLIResult {
        let process = AWSCLIProcess(arguments: arguments)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try process.run(timeout: timeout) })
                }
            }
        } onCancel: {
            process.stop(.cancelled)
        }
    }
}

private final nonisolated class AWSCLIProcess: @unchecked Sendable {
    enum StopReason { case timedOut, cancelled }

    private let lock = NSLock()
    private let process = Process()
    private var stopReason: StopReason?

    init(arguments: [String]) {
        self.process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        self.process.arguments = ["aws"] + arguments
        var environment = ProcessInfo.processInfo.environment
        // Apps opened from Finder get a minimal PATH; add Homebrew like TerminalService does.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["AWS_PAGER"] = ""
        self.process.environment = environment
        self.process.standardInput = FileHandle.nullDevice
    }

    func run(timeout: TimeInterval) throws -> AWSCLIResult {
        let output = Pipe()
        let errors = Pipe()
        let outputBuffer = AWSCLIBuffer(limit: 64 * 1024)
        let errorBuffer = AWSCLIBuffer(limit: 16 * 1024)
        self.process.standardOutput = output
        self.process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { handle in outputBuffer.drain(handle) }
        errors.fileHandleForReading.readabilityHandler = { handle in errorBuffer.drain(handle) }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }

        try self.lock.withLock {
            guard self.stopReason == nil else { throw CancellationError() }
            do {
                try self.process.run()
            } catch {
                throw AWSCLIError.cliNotFound
            }
        }
        let timeoutWork = DispatchWorkItem { [weak self] in self?.stop(.timedOut) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        self.process.waitUntilExit()
        timeoutWork.cancel()

        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        let stdout = outputBuffer.finish(output.fileHandleForReading)
        let stderr = errorBuffer.finish(errors.fileHandleForReading)
        let stopReason = self.lock.withLock { self.stopReason }
        switch stopReason {
        case .timedOut: throw AWSCLIError.timedOut
        case .cancelled: throw CancellationError()
        case nil: break
        }
        // `env` exits 127 when `aws` is not on the PATH.
        if self.process.terminationStatus == 127 {
            throw AWSCLIError.cliNotFound
        }
        return AWSCLIResult(
            exitCode: self.process.terminationStatus,
            stdout: String(bytes: stdout, encoding: .utf8) ?? "",
            stderr: String(bytes: stderr, encoding: .utf8) ?? ""
        )
    }

    func stop(_ reason: StopReason) {
        self.lock.withLock {
            guard self.stopReason == nil else { return }
            self.stopReason = reason
            if self.process.isRunning {
                self.process.terminate()
            }
        }
    }
}

private final nonisolated class AWSCLIBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func drain(_ handle: FileHandle) {
        self.lock.withLock {
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            }
            self.append(chunk)
        }
    }

    func finish(_ handle: FileHandle) -> Data {
        self.lock.withLock {
            while let chunk = try? handle.read(upToCount: 16_384), !chunk.isEmpty {
                self.append(chunk)
            }
            return self.data
        }
    }

    private func append(_ chunk: Data) {
        self.data.append(chunk.prefix(max(0, self.limit - self.data.count)))
    }
}
