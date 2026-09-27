//
//  CurseForgeWebScrapeAPI.swift
//  WoWAddonSync
//
//  The true last resort, tried only when an addon matches none of the
//  other three sources: WowInterface, GitHub, or the CurseForge local
//  scan (CurseForgeLocalScanAPI.swift — which needs the CurseForge
//  desktop app installed and granted). This source needs neither of
//  those: it fetches the addon's own public page on curseforge.com and
//  pulls the latest file's name/date straight out of the page's HTML.
//
//  Be clear-eyed about what this is: CurseForge's real API requires a
//  gated developer application, which this app deliberately avoids (see
//  CurseForgeLocalScanAPI.swift's header). Scraping the public page is
//  the only way left to get *any* independent version signal for an
//  addon that's CurseForge-only and whose owner doesn't run the
//  CurseForge desktop app. But the page's HTML is not a published,
//  versioned contract the way the GitHub/WowInterface APIs are — it's
//  whatever curseforge.com's frontend happens to render today, and it
//  can change layout at any time without notice. This parser is written
//  loosely on purpose (matching on visible text patterns, not exact CSS
//  classes or DOM structure) to survive small changes, but a bigger
//  redesign of that site will silently stop it from matching anything.
//  When that happens it fails quiet — no match, not wrong data — the
//  same "best-effort, never fatal" rule every other optional source in
//  this app follows.
//
//  How an addon gets a slug for this source in the first place: either a
//  manual override (AppSettings.manualCurseForgeSlugs), or automatically
//  when the addon's own `.toc` `X-Website` field already points at its
//  curseforge.com page (some addons put that there even without a
//  WowInterface ID or GitHub link).
//

import Foundation

// MARK: - Slug parsing

enum CurseForgeSlug {
    /// Parses a `.toc` `X-Website` value like
    /// "https://www.curseforge.com/wow/addons/clique" (optional trailing
    /// path/query, e.g. "/files/all") into just the "clique" slug.
    /// Returns nil for anything that isn't a curseforge.com addon URL.
    static func parse(fromWebsite website: String?) -> String? {
        guard let website, let url = URL(string: website),
              let host = url.host?.lowercased(),
              host == "curseforge.com" || host == "www.curseforge.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let addonsIndex = parts.firstIndex(where: { $0.lowercased() == "addons" }),
              addonsIndex + 1 < parts.count else { return nil }
        return parts[addonsIndex + 1]
    }
}

// MARK: - Scraped result

/// What was pulled off an addon's public CurseForge page. `fileId` and
/// `fileDate` are best-effort — either can come back nil if the page
/// didn't match this parser's expectations that time, even when
/// `displayName` did.
struct CurseForgeScrapedRelease: Equatable, Codable {
    var slug: String
    var displayName: String
    var fileId: Int?
    var fileDate: Date?
    var pageURL: URL

    /// CurseForge's website "direct download" link — appending `/file` to
    /// the page's own per-file download link skips the browser
    /// "preparing your download" interstitial and redirects straight to
    /// the CDN zip, the same kind of edge.forgecdn.net URL the local-scan
    /// source downloads from directly. This is an unpublished, unofficial
    /// behavior of curseforge.com's website, not an API contract — nil
    /// when there's no `fileId` to build it from, and liable to stop
    /// working if CurseForge changes it.
    var downloadURL: URL? {
        guard let fileId else { return nil }
        return URL(string: "https://www.curseforge.com/wow/addons/\(slug)/download/\(fileId)/file")
    }
}

enum CurseForgeWebScrapeError: LocalizedError {
    case httpError(status: Int)
    case transportError(Error)

    var errorDescription: String? {
        switch self {
        case .httpError(let status):
            return "CurseForge's website returned HTTP \(status) for that addon page."
        case .transportError(let error):
            return "Network error reading CurseForge's page: \(error.localizedDescription)"
        }
    }
}

// MARK: - Client

struct CurseForgeWebScrapeClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches `https://www.curseforge.com/wow/addons/<slug>` and parses
    /// its latest file out of the rendered HTML. Returns nil (not a
    /// throw) for a 404 or for a page whose layout this parser doesn't
    /// recognize — both are "no match," the same non-fatal outcome the
    /// other optional sources use; only real transport/HTTP failures
    /// throw.
    func latestFile(slug: String) async throws -> CurseForgeScrapedRelease? {
        guard let pageURL = URL(string: "https://www.curseforge.com/wow/addons/\(slug)") else { return nil }

        var request = URLRequest(url: pageURL)
        // A default URLSession request can get a stripped-down response
        // from some sites; a normal desktop-browser User-Agent is more
        // likely to get the same server-rendered page a person would see.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CurseForgeWebScrapeError.transportError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CurseForgeWebScrapeError.transportError(URLError(.badServerResponse))
        }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw CurseForgeWebScrapeError.httpError(status: http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else { return nil }

        return Self.parse(html: html, slug: slug, pageURL: pageURL)
    }

    /// The actual parsing, kept as a standalone static function (no
    /// network dependency) so it's the one piece of this file that could
    /// be re-run against saved HTML if this ever needs debugging without
    /// burning a live request.
    static func parse(html: String, slug: String, pageURL: URL) -> CurseForgeScrapedRelease? {
        // Flatten every tag to a space and collapse whitespace, so this
        // depends only on the page's visible text and word order — not on
        // exact class names or DOM nesting, which are exactly what a
        // frontend redesign would change first.
        let flattened = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let singleLine = flattened.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        // CurseForge labels exactly one file "Latest release" on an
        // addon's main page, right alongside that file's own name. Anchor
        // on that label rather than guessing at a version-number pattern,
        // which could just as easily match the game-version column
        // instead (e.g. "12.1.0").
        guard let anchorRegex = try? NSRegularExpression(pattern: "([A-Za-z0-9][A-Za-z0-9._\\-]{2,80})\\s+Latest release") else {
            return nil
        }
        let fullRange = NSRange(singleLine.startIndex..<singleLine.endIndex, in: singleLine)
        guard let anchorMatch = anchorRegex.firstMatch(in: singleLine, range: fullRange),
              let versionRange = Range(anchorMatch.range(at: 1), in: singleLine) else {
            // Didn't find the expected label at all — most likely this
            // page's layout has changed. Fail quietly rather than
            // guessing at a fallback pattern that's more likely to grab
            // the wrong text.
            return nil
        }
        let displayName = String(singleLine[versionRange])

        // A date like "Jul 31, 2026" somewhere shortly after that same
        // anchor — the rest of that file's own summary line.
        let searchLocation = anchorMatch.range.location
        let searchLength = min(300, (singleLine as NSString).length - searchLocation)
        let windowRange = NSRange(location: searchLocation, length: max(0, searchLength))
        let fileDate: Date? = {
            guard let dateRegex = try? NSRegularExpression(pattern: "\\b([A-Z][a-z]{2})\\s+(\\d{1,2}),\\s+(\\d{4})\\b"),
                  let match = dateRegex.firstMatch(in: singleLine, range: windowRange),
                  let dateRange = Range(match.range, in: singleLine) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.date(from: String(singleLine[dateRange]))
        }()

        // This addon's own per-file download links look like
        // /wow/addons/<slug>/download/<fileId>. CurseForge always lists
        // the newest file first, so the first one on the page is this
        // "Latest release" file's id.
        let fileId: Int? = {
            guard let regex = try? NSRegularExpression(
                pattern: "/wow/addons/\(NSRegularExpression.escapedPattern(for: slug))/download/(\\d+)",
                options: [.caseInsensitive]
            ) else { return nil }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, range: range),
                  let idRange = Range(match.range(at: 1), in: html) else { return nil }
            return Int(html[idRange])
        }()

        return CurseForgeScrapedRelease(slug: slug, displayName: displayName, fileId: fileId, fileDate: fileDate, pageURL: pageURL)
    }
}
