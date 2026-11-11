import Foundation
import XCTest
@testable import sand

final class MockAuth: GitHubAuthenticating, @unchecked Sendable {
    func token(now: Date) throws -> String {
        return "jwt"
    }
}

final class MockSession: URLSessionProtocol, @unchecked Sendable {
    var responses: [String: (Data, Int)] = [:]
    var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        guard let response = responses[path] else {
            throw NSError(domain: "missing", code: 1)
        }
        let url = request.url ?? URL(string: "https://api.github.com")!
        let http = HTTPURLResponse(url: url, statusCode: response.1, httpVersion: nil, headerFields: nil)!
        return (response.0, http)
    }
}

final class GitHubServiceTests: XCTestCase {
    func testRepoLevelPaths() async throws {
        let session = MockSession()
        session.responses["/repos/org/repo/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\"}".utf8), 200)
        session.responses["/repos/org/repo/actions/runners/registration-token"] = (Data("{\"token\":\"runner\"}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: "repo")
        let token = try await service.runnerRegistrationToken()
        XCTAssertEqual(token, "runner")
        XCTAssertEqual(session.requests.map { $0.url?.path ?? "" }, [
            "/repos/org/repo/installation",
            "/app/installations/1/access_tokens",
            "/repos/org/repo/actions/runners/registration-token"
        ])
    }

    func testDeleteRunnerLooksUpByNameThenDeletes() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"total_count\":1,\"runners\":[{\"id\":7,\"name\":\"runner 1+x\"}]}".utf8), 200)
        session.responses["/orgs/org/actions/runners/7"] = (Data(), 204)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let deleted = try await service.deleteRunner(named: "runner 1+x")
        XCTAssertTrue(deleted)
        XCTAssertEqual(session.requests[2].url?.query, "name=runner%201%2Bx")
        XCTAssertEqual(session.requests[3].httpMethod, "DELETE")
        XCTAssertEqual(session.requests[3].url?.path, "/orgs/org/actions/runners/7")
    }

    func testDeleteRunnerSkipsMissingRunner() async throws {
        let session = MockSession()
        session.responses["/repos/org/repo/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\"}".utf8), 200)
        session.responses["/repos/org/repo/actions/runners"] = (Data("{\"total_count\":0,\"runners\":[]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: "repo")
        let deleted = try await service.deleteRunner(named: "runner-1-abcde")
        XCTAssertFalse(deleted)
        XCTAssertEqual(session.requests.count, 3)
    }

    func testAPIBaseURLForEachServerForm() throws {
        let cases = [
            ("https://github.com", "https://api.github.com"),
            ("https://GitHub.com/", "https://api.github.com"),
            ("https://acme.ghe.com", "https://api.acme.ghe.com"),
            ("https://acme.ghe.com/", "https://api.acme.ghe.com"),
            ("https://ghes.example.com", "https://ghes.example.com/api/v3"),
            ("https://ghes.example.com:8443/", "https://ghes.example.com:8443/api/v3")
        ]
        for (serverURL, expected) in cases {
            let server = try XCTUnwrap(GitHubServer(string: serverURL), serverURL)
            XCTAssertEqual(server.apiBaseURL.absoluteString, expected, serverURL)
        }
    }

    func testAPIURLJoiningKeepsBasePathAndQuery() throws {
        let ghes = try XCTUnwrap(GitHubServer(string: "https://ghes.example.com")).apiBaseURL
        XCTAssertEqual(
            GitHubServer.apiURL(baseURL: ghes, path: "/repos/org/repo/installation")?.absoluteString,
            "https://ghes.example.com/api/v3/repos/org/repo/installation"
        )
        XCTAssertEqual(
            GitHubServer.apiURL(baseURL: ghes, path: "/orgs/org/actions/runners?name=a%20b")?.absoluteString,
            "https://ghes.example.com/api/v3/orgs/org/actions/runners?name=a%20b"
        )
        XCTAssertEqual(
            GitHubServer.apiURL(baseURL: URL(string: "https://ghes.example.com/api/v3/")!, path: "/app")?.absoluteString,
            "https://ghes.example.com/api/v3/app"
        )
        XCTAssertEqual(
            GitHubServer.apiURL(baseURL: GitHubServer.dotCom.apiBaseURL, path: "/orgs/org/installation")?.absoluteString,
            "https://api.github.com/orgs/org/installation"
        )
    }

    func testDefaultBaseURLIsGitHubDotCom() async throws {
        let session = MockSession()
        session.responses["/repos/org/repo/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\"}".utf8), 200)
        session.responses["/repos/org/repo/actions/runners/registration-token"] = (Data("{\"token\":\"runner\"}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: "repo")
        _ = try await service.runnerRegistrationToken()
        XCTAssertEqual(session.requests.map { $0.url?.absoluteString ?? "" }, [
            "https://api.github.com/repos/org/repo/installation",
            "https://api.github.com/app/installations/1/access_tokens",
            "https://api.github.com/repos/org/repo/actions/runners/registration-token"
        ])
    }

    func testGHEDotComRequestsGoToAPISubdomain() async throws {
        let session = MockSession()
        session.responses["/repos/org/repo/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\"}".utf8), 200)
        session.responses["/repos/org/repo/actions/runners/registration-token"] = (Data("{\"token\":\"runner\"}".utf8), 200)
        let baseURL = try XCTUnwrap(GitHubServer(string: "https://acme.ghe.com")).apiBaseURL
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: "repo", baseURL: baseURL)
        let token = try await service.runnerRegistrationToken()
        XCTAssertEqual(token, "runner")
        XCTAssertEqual(session.requests.map { $0.url?.absoluteString ?? "" }, [
            "https://api.acme.ghe.com/repos/org/repo/installation",
            "https://api.acme.ghe.com/app/installations/1/access_tokens",
            "https://api.acme.ghe.com/repos/org/repo/actions/runners/registration-token"
        ])
    }

    func testGHESRequestsKeepAPIV3Prefix() async throws {
        let session = MockSession()
        session.responses["/api/v3/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/api/v3/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\"}".utf8), 200)
        session.responses["/api/v3/orgs/org/actions/runners"] = (Data("{\"total_count\":1,\"runners\":[{\"id\":7,\"name\":\"runner 1+x\"}]}".utf8), 200)
        session.responses["/api/v3/orgs/org/actions/runners/7"] = (Data(), 204)
        let baseURL = try XCTUnwrap(GitHubServer(string: "https://ghes.example.com")).apiBaseURL
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil, baseURL: baseURL)
        let deleted = try await service.deleteRunner(named: "runner 1+x")
        XCTAssertTrue(deleted)
        XCTAssertEqual(session.requests.map { $0.url?.absoluteString ?? "" }, [
            "https://ghes.example.com/api/v3/orgs/org/installation",
            "https://ghes.example.com/api/v3/app/installations/1/access_tokens",
            "https://ghes.example.com/api/v3/orgs/org/actions/runners?name=runner%201%2Bx",
            "https://ghes.example.com/api/v3/orgs/org/actions/runners/7"
        ])
        XCTAssertEqual(session.requests[2].url?.query, "name=runner%201%2Bx")
    }
}
