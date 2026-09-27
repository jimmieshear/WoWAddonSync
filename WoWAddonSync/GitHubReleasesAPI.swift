//
//  GitHubReleasesAPI.swift
//  WoWAddonSync
//
//  A version source for addons that don't publish to WowInterface at all
//  and are instead distributed as GitHub Releases — common for smaller or
//  developer-facing addons. No key needed for this either: GitHub's
//  releases API is public for public repos (rate-limited to 60
//  requests/hour per network when unauthenticated, which is generous for
//  how often this app actually syncs).
//
//  The repo is found one of two ways:
//   - Automatically, from the addon's own `.toc` `X-Website` field, when
//     it's a github.com URL (see GitHubRepoRef.init(website:)). Packaging
//     tools don't have a dedicated "X-GitHub-Repo" field the way they do
//     for WowInterface/CurseForge/Wago, so this is a best-effort read of
//     whatever URL the author already put in their .toc for humans.
//   - Manually, entered in the addon's detail view, for addons whose
//     `.toc` doesn't point at GitHub at all (or doesn't have an
//     X-Website field) — see AppSettings.manualGitHubRepos.
//
//  Only an actual uploaded release *asset* (a .zip file attached to the
//  release) is used — never GitHub's auto-generated "Source code (zip)"
//  archive. That auto archive's top-level folder is named
//  "{repo}-{tag}", not the addon's real folder name, and it includes repo
//  files (README, .github/, LICENSE, ...) that don't belong in AddOns —
//  installing it as-is would silently produce the wrong folder structure.
//  If a release has no .zip asset, this app treats it as "nothing to
//  install" rather than guessing.
//

import Foundation

// MARK: - Repo reference

struct GitHubRepoRef: Equatable, Codable {
    var owner: String
    var repo: String

    var spec: String { "\(owner)/\(repo)" }
    var htmlURL: URL? { URL(string: "https://github.com/\(owner)/\(repo)") }

    /// Parses manual entry from the addon detail view: either a bare
    /// "owner/repo" or a full github.com URL, either works.
    init?(spec: String) {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let fromURL = GitHubRepoRef(website: trimmed) {
            self = fromURL
            return
        }
        let parts = trimmed.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        owner = parts[0]
        repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
    }

    /// Parses a `.toc` `X-Website` value like
    /// "https://github.com/Owner/Repo" (optional trailing slash, path, or
    /// query string) into an owner/repo pair. Returns nil for anything
    /// that isn't a github.com URL naming a repo.
    init?(website: String?) {
        guard let website, let url = URL(string: website),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        owner = parts[0]
        repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
    }
}

// MARK: - Latest release

struct GitHubLatestRelease: Equatable, Codable {
    var repo: GitHubRepoRef
    var tag: String
    var displayName: String
    var publishedAt: Date
    var downloadUrl: URL?
}

// MARK: - Errors

enum GitHubReleasesError: LocalizedError {
    case httpError(status: Int)
    case rateLimited
    case decodingFailed(Error)
    case transportError(Error)
    case missingDownloadURL

    var errorDescription: String? {
        switch self {
        case .httpError(let status):
            return "GitHub API returned HTTP \(status)."
        case .rateLimited:
            return "GitHub's API rate limit was hit (60 unauthenticated requests/hour, shared by everything on this network) — this will clear on its own within the hour."
        case .decodingFailed(let error):
            return "Couldn't parse GitHub's response: \(error.localizedDescription)"
        case .transportError(let error):
            return "Network error talking to GitHub: \(error.localizedDescription)"
        case .missingDownloadURL:
            return "This GitHub release has no .zip file attached to it (only an auto-generated source archive, which isn't safe to install as an addon) — nothing to sync."
        }
    }
}

// MARK: - Client

final class GitHubReleasesClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches the newest non-prerelease, non-draft release for a repo
    /// (GitHub's `/releases/latest` already excludes both). Returns nil
    /// for a 404 (no releases at all, or the repo doesn't exist) rather
    /// than throwing — that's a normal outcome, not an error.
    func latestRelease(for repoRef: GitHubRepoRef) async throws -> GitHubLatestRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(repoRef.owner)/\(repoRef.repo)/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub's API requires a User-Agent on every request.
        request.setValue("WoWAddonSync", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GitHubReleasesError.transportError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GitHubReleasesError.transportError(URLError(.badServerResponse))
        }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 403 || http.statusCode == 429 {
            throw GitHubReleasesError.rateLimited
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubReleasesError.httpError(status: http.statusCode)
        }

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        struct ReleaseResponse: Decodable {
            let tag_name: String
            let name: String?
            let published_at: String
            let assets: [Asset]
        }

        let decoded: ReleaseResponse
        do {
            decoded = try JSONDecoder().decode(ReleaseResponse.self, from: data)
        } catch {
            throw GitHubReleasesError.decodingFailed(error)
        }

        // Prefer a .zip asset that doesn't look flavor-specific (Classic/
        // Vanilla/Wrath/Cata) over one that does, since this app targets
        // retail; fall back to whatever .zip is there if that's all a
        // repo publishes.
        let zipAssets = decoded.assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        let flavorHints = ["classic", "vanilla", "wotlk", "wrath", "cata", "tbc", "bcc", "mists"]
        let chosen = zipAssets.first(where: { asset in
            !flavorHints.contains(where: { asset.name.lowercased().contains($0) })
        }) ?? zipAssets.first

        let publishedAt = ISO8601DateFormatter().date(from: decoded.published_at) ?? Date()
        let displayName = (decoded.name?.isEmpty == false ? decoded.name! : nil) ?? decoded.tag_name

        return GitHubLatestRelease(
            repo: repoRef,
            tag: decoded.tag_name,
            displayName: displayName,
            publishedAt: publishedAt,
            downloadUrl: chosen.flatMap { URL(string: $0.browser_download_url) }
        )
    }

    /// Same temp-file-lifetime handling as the other clients — URLSession's
    /// own temp file isn't guaranteed to outlive this call.
    func downloadFile(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("WoWAddonSync", forHTTPHeaderField: "User-Agent")

        let downloadedURL: URL
        let response: URLResponse
        do {
            (downloadedURL, response) = try await session.download(for: request)
        } catch {
            throw GitHubReleasesError.transportError(error)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GitHubReleasesError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("WoWAddonSync-github-download-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: downloadedURL, to: destination)
        } catch {
            throw GitHubReleasesError.transportError(error)
        }
        return destination
    }
}
