import Foundation

enum GitHubServerError: Error, Equatable {
    case invalidServerURL(String)
}

/// The GitHub instance runners register with: github.com, GitHub Enterprise Cloud
/// with data residency (`*.ghe.com`), or GitHub Enterprise Server.
struct GitHubServer: Equatable, Sendable {
    static let defaultURL = "https://github.com"
    static let dotCom = GitHubServer(string: defaultURL)!

    /// Web root without a trailing slash, e.g. `https://acme.ghe.com`. Passed to `config.sh --url`.
    let webURL: String
    /// REST API root without a trailing slash.
    let apiBaseURL: URL

    /// Accepts an https URL with a host and no path, query or credentials. A trailing `/` is allowed.
    init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host, !rawHost.isEmpty,
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil
        else {
            return nil
        }
        let host = rawHost.lowercased()
        let authority = host + (components.port.map { ":\($0)" } ?? "")
        let api: String
        if host == "github.com" {
            api = "https://api.github.com"
        } else if host.hasSuffix(".ghe.com") {
            api = "https://api.\(authority)"
        } else {
            api = "https://\(authority)/api/v3"
        }
        guard let apiBaseURL = URL(string: api) else {
            return nil
        }
        self.webURL = "https://\(authority)"
        self.apiBaseURL = apiBaseURL
    }

    func runnerURL(organization: String, repository: String?) -> String {
        if let repository {
            return "\(webURL)/\(organization)/\(repository)"
        }
        return "\(webURL)/\(organization)"
    }

    /// Joins an absolute API path (`/repos/...`, may carry a query) onto `baseURL`.
    /// Plain concatenation keeps a base path such as GHES `/api/v3`, which
    /// `URL(string:relativeTo:)` drops for paths that start with `/`.
    static func apiURL(baseURL: URL, path: String) -> URL? {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") {
            base.removeLast()
        }
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: base + suffix)
    }
}
