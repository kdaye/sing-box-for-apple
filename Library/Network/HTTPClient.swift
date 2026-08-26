import Foundation
import Libbox

public enum ConditionalHTTPResult: Equatable, Sendable {
    case modified(content: String, etag: String?)
    case notModified(etag: String?)
}

public class HTTPClient {
    private static var userAgent: String {
        var userAgent = Variant.applicationName
        userAgent += " (sing-box "
        userAgent += LibboxVersion()
        userAgent += "; language "
        userAgent += Locale.current.identifier
        userAgent += ")"
        return userAgent
    }

    private let client: any LibboxHTTPClientProtocol

    public init() {
        client = LibboxNewHTTPClient()!
        client.modernTLS()
    }

    public func getString(_ url: String?) throws -> String {
        #if DEBUG
            precondition(!Thread.isMainThread, "HTTPClient.getString(...) must not be called on the main thread")
        #endif
        let request = client.newRequest()!
        request.setUserAgent(HTTPClient.userAgent)
        try request.setURL(url)
        let response = try request.execute()
        let content = try response.getContent()
        return content.value
    }

    public func getStringAsync(_ url: String?) async throws -> String {
        try await Self.getStringAsync(url)
    }

    public static func getStringAsync(_ url: String?) async throws -> String {
        try await BlockingIO.run {
            try HTTPClient().getString(url)
        }
    }

    public static func getStringConditionalAsync(_ url: String?, etag: String?) async throws -> ConditionalHTTPResult {
        let request = try makeRequest(url: url, etag: etag)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return try decodeConditionalResponse(data: data, response: response)
    }

    static func makeRequest(url: String?, etag: String?) throws -> URLRequest {
        guard let url, let requestURL = URL(string: url) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: requestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }

    static func decodeConditionalResponse(data: Data, response: HTTPURLResponse) throws -> ConditionalHTTPResult {
        let etag = response.value(forHTTPHeaderField: "ETag")
        if response.statusCode == 304 {
            return .notModified(etag: etag)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return .modified(content: String(decoding: data, as: UTF8.self), etag: etag)
    }

    public func writeTo(_ url: String?, path: String, progress: ((Int64, Int64) -> Void)? = nil) throws {
        #if DEBUG
            precondition(!Thread.isMainThread, "HTTPClient.writeTo(...) must not be called on the main thread")
        #endif
        let request = client.newRequest()!
        request.setUserAgent(HTTPClient.userAgent)
        try request.setURL(url)
        let response = try request.execute()
        if let progress {
            let handler = WriteToProgressHandler(progress)
            try response.writeTo(withProgress: path, handler: handler)
        } else {
            try response.write(to: path)
        }
    }

    public static func writeToAsync(_ url: String?, path: String, progress: ((Int64, Int64) -> Void)? = nil) async throws {
        try await BlockingIO.run {
            try HTTPClient().writeTo(url, path: path, progress: progress)
        }
    }

    deinit {
        client.close()
    }
}

private class WriteToProgressHandler: NSObject, LibboxHTTPResponseWriteToProgressHandlerProtocol {
    private let handler: (Int64, Int64) -> Void

    init(_ handler: @escaping (Int64, Int64) -> Void) {
        self.handler = handler
    }

    func update(_ progress: Int64, total: Int64) {
        handler(progress, total)
    }
}
