import Foundation

/// A release version like "0.10.2", compared number by number (1.10 is newer than 1.9).
/// Missing parts count as zero, so "1.2" and "1.2.0" are the same version.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let numbers: [Int]

    /// Accepts "0.3.0", "v0.3.0" and build metadata ("1.0.0+5"). A prerelease ("1.0.0-beta.1") and
    /// anything that is not a dotted list of numbers give nil: such a tag is never offered as an update.
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        self.numbers = numbers
    }

    public var description: String { numbers.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// The newest published release, as far as the update check needs it.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: AppVersion
    public let tag: String
    /// The release page on GitHub, opened in the browser. Never a download.
    public let pageURL: URL

    public init(version: AppVersion, tag: String, pageURL: URL) {
        self.version = version
        self.tag = tag
        self.pageURL = pageURL
    }

    /// Restores a release remembered from an earlier check (nil when the stored values are unusable).
    public init?(tag: String, pageURL: String) {
        guard let version = AppVersion(tag), let url = URL(string: pageURL), UpdateCheck.isReleasePage(url) else { return nil }
        self.init(version: version, tag: tag, pageURL: url)
    }
}

public enum UpdateCheckError: Error, Equatable, Sendable {
    /// No connection, DNS failure or timeout.
    case offline
    /// GitHub limits unauthenticated API calls per IP address (403 or 429).
    case rateLimited
    case httpStatus(Int)
    /// A captive portal or proxy answered with a web page instead of JSON.
    case notJSON
    /// JSON, but without a usable tag or release page.
    case invalidRelease
    case network(String)
}

public enum UpdateCheckOutcome: Equatable, Sendable {
    case upToDate
    case updateAvailable(ReleaseInfo)
}

/// Asks GitHub once a day whether a newer release exists. Sends nothing but the request itself: no
/// cookies, no identifiers, no usage data. Shows a hint; it never downloads or installs anything.
public enum UpdateCheck {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/ursalfas11/saywrite/releases/latest")!
    /// Shown when the API's page link is unusable.
    public static let releasesPageURL = URL(string: "https://github.com/ursalfas11/saywrite/releases")!
    /// At most one automatic check per day.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// Whether an automatic check is due. A last check in the future (the clock was set back) does not
    /// block checks until that date comes around again.
    public static func isDue(enabled: Bool, lastCheck: Date?, now: Date, interval: TimeInterval = UpdateCheck.interval) -> Bool {
        guard enabled else { return false }
        guard let lastCheck, lastCheck <= now else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// Only release pages of this repository are opened from the menu.
    public static func isReleasePage(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com"
            && url.path.hasPrefix("/ursalfas11/saywrite/releases")
    }

    /// The request: JSON only, no cookies, no cache, short timeout.
    public static func makeRequest(timeout: TimeInterval = 10) -> URLRequest {
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub requires a User-Agent; a fixed one instead of the default, which names the app build and the OS version.
        request.setValue("Saywrite-update-check", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        return request
    }

    /// A session that keeps nothing: no cookies, no cache, no credentials, and redirects only within api.github.com.
    public static func makeSession(timeout: TimeInterval = 10) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: SameHostRedirects(), delegateQueue: nil)
    }

    /// The newest stable release from a `releases/latest` answer, or nil for a draft or prerelease
    /// (that endpoint should not return either, but neither is ever offered).
    public static func parseRelease(_ data: Data) throws -> ReleaseInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data), let json = object as? [String: Any] else {
            throw UpdateCheckError.notJSON
        }
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { return nil }
        guard let tag = json["tag_name"] as? String else { throw UpdateCheckError.invalidRelease }
        // A tag with a prerelease suffix ("v1.0.0-rc.1") counts as a prerelease even without the flag.
        guard let version = AppVersion(tag) else {
            if tag.contains("-") { return nil }
            throw UpdateCheckError.invalidRelease
        }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)).flatMap { isReleasePage($0) ? $0 : nil }
        return ReleaseInfo(version: version, tag: tag, pageURL: page ?? releasesPageURL)
    }

    /// Turns the HTTP answer into an outcome. Errors are for the "Check now" button and the debug log;
    /// the automatic check ignores them.
    public static func interpret(status: Int, contentType: String?, data: Data, currentVersion: String) -> Result<UpdateCheckOutcome, UpdateCheckError> {
        switch status {
        case 200: break
        // No release published (yet): nothing to offer.
        case 404: return .success(.upToDate)
        case 403, 429: return .failure(.rateLimited)
        default: return .failure(.httpStatus(status))
        }
        if let contentType, !contentType.lowercased().contains("json") { return .failure(.notJSON) }
        do {
            guard let release = try parseRelease(data) else { return .success(.upToDate) }
            return .success(outcome(latest: release, currentVersion: currentVersion))
        } catch let error as UpdateCheckError {
            return .failure(error)
        } catch {
            return .failure(.invalidRelease)
        }
    }

    /// Newer than the running version, or up to date. An unreadable running version offers nothing.
    public static func outcome(latest: ReleaseInfo, currentVersion: String) -> UpdateCheckOutcome {
        guard let current = AppVersion(currentVersion), current < latest.version else { return .upToDate }
        return .updateAvailable(latest)
    }

    public static func classify(_ error: Error) -> UpdateCheckError {
        if let error = error as? UpdateCheckError { return error }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                return .offline
            default:
                return .network(error.localizedDescription)
            }
        }
        return .network(error.localizedDescription)
    }

    /// One check against GitHub.
    public static func check(currentVersion: String, session: URLSession) async -> Result<UpdateCheckOutcome, UpdateCheckError> {
        do {
            let (data, response) = try await session.data(for: makeRequest())
            guard let http = response as? HTTPURLResponse else { return .failure(.network("no HTTP response")) }
            return interpret(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"),
                             data: data, currentVersion: currentVersion)
        } catch {
            return .failure(classify(error))
        }
    }
}
