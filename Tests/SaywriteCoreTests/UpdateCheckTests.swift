import XCTest
@testable import SaywriteCore

/// The update hint: version comparison, the GitHub answer and the daily limit.
final class UpdateCheckTests: XCTestCase {
    private func release(_ json: String) throws -> ReleaseInfo? {
        try UpdateCheck.parseRelease(Data(json.utf8))
    }

    private func version(_ text: String) -> AppVersion { AppVersion(text)! }

    func testVersionsCompareNumberByNumber() {
        XCTAssertLessThan(version("1.9"), version("1.10"))
        XCTAssertLessThan(version("0.2.0"), version("0.3.0"))
        XCTAssertLessThan(version("0.2.9"), version("0.10.0"))
        XCTAssertLessThan(version("1.2"), version("1.2.1"))
        XCTAssertLessThan(version("v0.9.9"), version("1"))
        XCTAssertEqual(version("1.2"), version("1.2.0"))
        XCTAssertEqual(version("v0.3.0"), version("0.3.0"))
        XCTAssertEqual(version("1.0.0+7"), version("1.0.0"))
        XCTAssertFalse(version("0.3.0") < version("0.3.0"))
        XCTAssertEqual(version("V2.01").description, "2.1")
    }

    func testPrereleaseAndJunkTagsAreNoVersion() {
        for text in ["1.0.0-beta.1", "v0.3.0-rc1", "", "v", "latest", "1..2", "1.2.", "1.x", "1.2.3.4.5", "-1.0", "١.٢"] {
            XCTAssertNil(AppVersion(text), text)
        }
    }

    func testParsesStableRelease() throws {
        let info = try release("""
            {"tag_name": "v0.3.0", "html_url": "https://github.com/ursalfas11/saywrite/releases/tag/v0.3.0",
             "draft": false, "prerelease": false, "name": "Saywrite v0.3.0", "assets": []}
            """)
        XCTAssertEqual(info?.tag, "v0.3.0")
        XCTAssertEqual(info?.version, version("0.3.0"))
        XCTAssertEqual(info?.pageURL.absoluteString, "https://github.com/ursalfas11/saywrite/releases/tag/v0.3.0")
    }

    func testIgnoresDraftsAndPrereleases() throws {
        XCTAssertNil(try release(#"{"tag_name": "v0.4.0", "html_url": "https://github.com/ursalfas11/saywrite/releases/tag/v0.4.0", "draft": true, "prerelease": false}"#))
        XCTAssertNil(try release(#"{"tag_name": "v0.4.0", "html_url": "https://github.com/ursalfas11/saywrite/releases/tag/v0.4.0", "draft": false, "prerelease": true}"#))
        // A prerelease suffix in the tag counts even without the flag.
        XCTAssertNil(try release(#"{"tag_name": "v0.4.0-beta.2", "draft": false, "prerelease": false}"#))
    }

    func testForeignReleasePageFallsBackToTheReleasesList() throws {
        for page in ["https://example.com/saywrite", "http://github.com/ursalfas11/saywrite/releases/tag/v1.0.0",
                     "https://github.com/someone/else/releases/tag/v1.0.0", "javascript:alert(1)"] {
            let info = try release(#"{"tag_name": "v1.0.0", "html_url": "\#(page)"}"#)
            XCTAssertEqual(info?.pageURL, UpdateCheck.releasesPageURL, page)
        }
        XCTAssertEqual(try release(#"{"tag_name": "v1.0.0"}"#)?.pageURL, UpdateCheck.releasesPageURL)
    }

    func testBrokenAnswersThrow() {
        XCTAssertThrowsError(try release("<!DOCTYPE html><html><body>Sign in to the network</body></html>")) {
            XCTAssertEqual($0 as? UpdateCheckError, .notJSON)
        }
        XCTAssertThrowsError(try release(#"["v1.0.0"]"#)) { XCTAssertEqual($0 as? UpdateCheckError, .notJSON) }
        XCTAssertThrowsError(try release(#"{"message": "Not Found"}"#)) { XCTAssertEqual($0 as? UpdateCheckError, .invalidRelease) }
        XCTAssertThrowsError(try release(#"{"tag_name": "nightly"}"#)) { XCTAssertEqual($0 as? UpdateCheckError, .invalidRelease) }
    }

    func testInterpretsHTTPAnswers() {
        let body = Data(#"{"tag_name": "v0.3.0", "html_url": "https://github.com/ursalfas11/saywrite/releases/tag/v0.3.0"}"#.utf8)
        let json = "application/json; charset=utf-8"
        guard case .success(.updateAvailable(let info)) = UpdateCheck.interpret(status: 200, contentType: json, data: body, currentVersion: "0.2.0") else {
            return XCTFail("0.3.0 is newer than 0.2.0")
        }
        XCTAssertEqual(info.tag, "v0.3.0")
        XCTAssertEqual(UpdateCheck.interpret(status: 200, contentType: json, data: body, currentVersion: "0.3.0"), .success(.upToDate))
        XCTAssertEqual(UpdateCheck.interpret(status: 200, contentType: json, data: body, currentVersion: "0.10.0"), .success(.upToDate))
        // An unreadable running version never offers an update.
        XCTAssertEqual(UpdateCheck.interpret(status: 200, contentType: json, data: body, currentVersion: "dev"), .success(.upToDate))
        XCTAssertEqual(UpdateCheck.interpret(status: 404, contentType: json, data: Data(), currentVersion: "0.2.0"), .success(.upToDate))
        XCTAssertEqual(UpdateCheck.interpret(status: 403, contentType: json, data: Data(), currentVersion: "0.2.0"), .failure(.rateLimited))
        XCTAssertEqual(UpdateCheck.interpret(status: 429, contentType: json, data: Data(), currentVersion: "0.2.0"), .failure(.rateLimited))
        XCTAssertEqual(UpdateCheck.interpret(status: 502, contentType: "text/html", data: Data(), currentVersion: "0.2.0"), .failure(.httpStatus(502)))
        XCTAssertEqual(UpdateCheck.interpret(status: 200, contentType: "text/html", data: body, currentVersion: "0.2.0"), .failure(.notJSON))
        XCTAssertEqual(UpdateCheck.interpret(status: 200, contentType: nil, data: Data("<html></html>".utf8), currentVersion: "0.2.0"), .failure(.notJSON))
    }

    func testChecksAtMostOncePerDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hour: TimeInterval = 60 * 60
        XCTAssertTrue(UpdateCheck.isDue(enabled: true, lastCheck: nil, now: now))
        XCTAssertFalse(UpdateCheck.isDue(enabled: true, lastCheck: now, now: now))
        XCTAssertFalse(UpdateCheck.isDue(enabled: true, lastCheck: now - 23 * hour, now: now))
        XCTAssertTrue(UpdateCheck.isDue(enabled: true, lastCheck: now - 24 * hour, now: now))
        XCTAssertTrue(UpdateCheck.isDue(enabled: true, lastCheck: now - 30 * 24 * hour, now: now))
        // The clock was set back: a "last check" in the future must not block checks for days.
        XCTAssertTrue(UpdateCheck.isDue(enabled: true, lastCheck: now + 5 * hour, now: now))
        // Switched off: never, whatever the date.
        XCTAssertFalse(UpdateCheck.isDue(enabled: false, lastCheck: nil, now: now))
        XCTAssertFalse(UpdateCheck.isDue(enabled: false, lastCheck: now - 30 * 24 * hour, now: now))
    }

    func testRequestCarriesNothingButTheQuestion() {
        let request = UpdateCheck.makeRequest()
        XCTAssertEqual(request.url, UpdateCheck.latestReleaseURL)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Saywrite-update-check")
        XCTAssertLessThanOrEqual(request.timeoutInterval, 15)
        let session = UpdateCheck.makeSession()
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertNil(session.configuration.urlCache)
    }

    func testRememberedReleaseIsRestoredOnlyFromAReleasePage() {
        XCTAssertEqual(ReleaseInfo(tag: "v0.3.0", pageURL: "https://github.com/ursalfas11/saywrite/releases/tag/v0.3.0")?.version, version("0.3.0"))
        XCTAssertNil(ReleaseInfo(tag: "v0.3.0", pageURL: "https://example.com/"))
        XCTAssertNil(ReleaseInfo(tag: "v0.3.0-beta", pageURL: "https://github.com/ursalfas11/saywrite/releases/tag/v0.3.0-beta"))
    }

    func testOfflineErrorsAreClassified() {
        XCTAssertEqual(UpdateCheck.classify(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(UpdateCheck.classify(URLError(.timedOut)), .offline)
        XCTAssertEqual(UpdateCheck.classify(UpdateCheckError.rateLimited), .rateLimited)
        if case .network = UpdateCheck.classify(URLError(.badServerResponse)) {} else { XCTFail("other URL errors stay network errors") }
    }

    func testCheckAgainstAStubServer() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubURLProtocol.reset { _ in
            StubURLProtocol.Answer(status: 200, headers: ["Content-Type": "application/json"],
                                   body: Data(#"{"tag_name": "v0.3.0", "html_url": "https://github.com/ursalfas11/saywrite/releases/tag/v0.3.0", "draft": false, "prerelease": false}"#.utf8))
        }
        let result = await UpdateCheck.check(currentVersion: "0.2.0", session: session)
        guard case .success(.updateAvailable(let info)) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(info.version, version("0.3.0"))
        let sent = StubURLProtocol.recorded
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.url, UpdateCheck.latestReleaseURL)
        XCTAssertNil(sent.first?.value(forHTTPHeaderField: "Cookie"))

        StubURLProtocol.reset { _ in StubURLProtocol.Answer(status: 403, headers: ["Content-Type": "application/json"]) }
        let limited = await UpdateCheck.check(currentVersion: "0.2.0", session: session)
        XCTAssertEqual(limited, .failure(.rateLimited))
    }
}
