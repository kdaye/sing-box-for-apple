import Foundation
import XCTest
@testable import ApplicationLibrary
@testable import Library

final class RemoteProfileCachingTests: XCTestCase {
    func testAuthenticatedConfigurationURLUsesYearHashAndSingConfPath() throws {
        let url = try AuthenticatedConfigurationURL.make(year: 2026)

        XCTAssertEqual(
            url.absoluteString,
            "https://www.sanzhihema.com/sing.conf?key=9f0b4919a55b0150b4afd5efe5889c45b96cd389e69982ee2143a1bc1c8a391c"
        )
    }

    func testForcedProfileRefreshDoesNotSendStoredETag() {
        XCTAssertNil(ProfileUpdateMode.forced.requestETag(storedETag: #""configuration-v2""#))
        XCTAssertEqual(
            ProfileUpdateMode.automatic.requestETag(storedETag: #""configuration-v2""#),
            #""configuration-v2""#
        )
    }

    func testProfileUpdateDiagnosticsPersistSourceAndOriginalFailure() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try ProfileUpdateDiagnostics.append(
            source: .automatic,
            event: "download failed: HTTP 403",
            at: Date(timeIntervalSince1970: 0),
            fileURL: fileURL
        )

        let report = try ProfileUpdateDiagnostics.read(fileURL: fileURL)
        XCTAssertEqual(report, "1970-01-01T00:00:00.000Z [automatic] download failed: HTTP 403\n")
    }

    func testMissingLocalProfileContentRequiresInitialRedownload() {
        let missingFile = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        let deniedFile = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)

        XCTAssertTrue(Profile.shouldRedownloadMissingRemoteContent(after: missingFile))
        XCTAssertFalse(Profile.shouldRedownloadMissingRemoteContent(after: deniedFile))
    }

    func testProfileUpdateDiagnosticsRotateToBoundedSize() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        for index in 0 ..< 5_000 {
            try ProfileUpdateDiagnostics.append(source: .automatic, event: "event \(index)", fileURL: fileURL)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = try XCTUnwrap(attributes[.size] as? NSNumber).intValue
        XCTAssertLessThanOrEqual(size, ProfileUpdateDiagnostics.maximumFileBytes)
        XCTAssertTrue(try ProfileUpdateDiagnostics.read(fileURL: fileURL).contains("event 4999"))
    }

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
