import Foundation
import XCTest
@testable import ApplicationLibrary
@testable import Library

final class RemoteProfileCachingTests: XCTestCase {
    func testTenMinuteProfileIntervalIsNotRaisedByScheduler() {
        let profile = Profile(
            name: "Network Tools",
            type: .remote,
            path: "config.json",
            remoteURL: "https://www.sanzhihema.com/sing.conf",
            autoUpdate: true,
            autoUpdateInterval: 10,
            lastUpdated: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(profile.autoUpdateIntervalOrDefault, 10 * 60)
        XCTAssertLessThanOrEqual(ProfileUpdateTask.minUpdateInterval, 10 * 60)
    }

    func testConditionalRequestSendsStoredETag() throws {
        let request = try HTTPClient.makeRequest(
            url: "https://www.sanzhihema.com/sing.conf",
            etag: #""configuration-v2""#
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), #""configuration-v2""#)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testNotModifiedResponseDoesNotProvideReplacementContent() throws {
        let response = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://www.sanzhihema.com/sing.conf")),
            statusCode: 304,
            httpVersion: nil,
            headerFields: ["ETag": #""configuration-v2""#]
        )!

        let result = try HTTPClient.decodeConditionalResponse(data: Data(), response: response)

        XCTAssertEqual(result, .notModified(etag: #""configuration-v2""#))
    }

    func testSuccessfulResponseReturnsContentAndNewETag() throws {
        let response = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://www.sanzhihema.com/sing.conf")),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["ETag": #""configuration-v3""#]
        )!

        let result = try HTTPClient.decodeConditionalResponse(
            data: Data("{\"log\":{}}".utf8),
            response: response
        )

        XCTAssertEqual(result, .modified(content: "{\"log\":{}}", etag: #""configuration-v3""#))
    }
}
