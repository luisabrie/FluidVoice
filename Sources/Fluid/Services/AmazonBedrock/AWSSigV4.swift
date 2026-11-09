import CryptoKit
import Foundation

nonisolated struct AWSCredentials: Sendable {
    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String?
    let expiration: Date?
}

/// AWS Signature Version 4. Signs `host`, `x-amz-date`, and the session token.
nonisolated enum AWSSigV4 {
    static func sign(_ request: inout URLRequest, credentials: AWSCredentials, region: String, service: String, date: Date = Date()) {
        guard let url = request.url, let host = url.host?.lowercased() else { return }
        let timestamp = self.timestamp(date)
        let day = String(timestamp.prefix(8))
        let token = credentials.sessionToken.flatMap { $0.isEmpty ? nil : $0 }

        request.setValue(timestamp, forHTTPHeaderField: "X-Amz-Date")
        if let token {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        var headers = [("host", host), ("x-amz-date", timestamp)]
        if let token {
            headers.append(("x-amz-security-token", token))
        }
        headers.sort { $0.0 < $1.0 }
        let canonicalHeaders = headers.map { "\($0.0):\($0.1.trimmingCharacters(in: .whitespaces))\n" }.joined()
        let signedHeaders = headers.map(\.0).joined(separator: ";")

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            self.canonicalURI(url),
            self.canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            self.hex(SHA256.hash(data: request.httpBody ?? Data())),
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            scope,
            self.hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    /// RFC 3986 encoding with AWS's unreserved set.
    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: self.unreserved) ?? value
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    /// Services other than S3 sign each path segment encoded twice; the wire path is already encoded once.
    private static func canonicalURI(_ url: URL) -> String {
        let path = url.path(percentEncoded: true)
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { self.encode(String($0)) }
            .joined(separator: "/")
    }

    private static func canonicalQuery(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty else { return "" }
        let pairs: [(name: String, value: String)] = items.map { item in
            (name: self.encode(item.name), value: self.encode(item.value ?? ""))
        }
        let sorted = pairs.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        return sorted.map { pair in pair.name + "=" + pair.value }.joined(separator: "&")
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.dateSeparator(.omitted).timeSeparator(.omitted))
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
