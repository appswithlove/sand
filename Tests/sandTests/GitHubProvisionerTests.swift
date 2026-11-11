import Foundation
import XCTest
@testable import sand

final class GitHubProvisionerTests: XCTestCase {
    private func config(
        repository: String? = nil,
        extraLabels: [String]? = nil,
        runnerGroup: String? = nil,
        serverURL: String? = nil
    ) -> GitHubProvisionerConfig {
        GitHubProvisionerConfig(
            appId: 1,
            organization: "org",
            repository: repository,
            privateKeyPath: "/tmp/key.pem",
            runnerName: "runner-1",
            extraLabels: extraLabels,
            runnerGroup: runnerGroup,
            serverURL: serverURL
        )
    }

    func testScriptExtractsCopiedTarballAndRegisters() throws {
        let script = try GitHubProvisioner().script(config: config(repository: "repo"), runnerName: "runner-1-0a1b2", runnerToken: "token")
        XCTAssertEqual(script, [
            "rm -rf ~/actions-runner && mkdir ~/actions-runner",
            "tar xzf ~/actions-runner.tar.gz -C ~/actions-runner",
            "echo \"Runner extracted\"",
            "~/actions-runner/config.sh --url https://github.com/org/repo --name runner-1-0a1b2 --token token --ephemeral --unattended --replace --labels sand",
            "echo \"Runner configured, starting ~/actions-runner/run.sh\"",
            "~/actions-runner/run.sh"
        ])
    }

    func testScriptNeverDownloadsInGuest() throws {
        let joined = try GitHubProvisioner().script(config: config(), runnerName: "runner-1", runnerToken: "token").joined(separator: "\n")
        XCTAssertFalse(joined.contains("curl"))
        XCTAssertTrue(joined.contains("--url https://github.com/org --name"))
    }

    func testScriptWithExtraLabels() throws {
        let joined = try GitHubProvisioner().script(config: config(extraLabels: ["fast", "arm64"]), runnerName: "runner-1", runnerToken: "token").joined(separator: "\n")
        XCTAssertTrue(joined.contains("--labels sand,fast,arm64"))
    }

    func testScriptRegistersIntoQuotedRunnerGroup() throws {
        let joined = try GitHubProvisioner().script(config: config(runnerGroup: "Mac Fleet's"), runnerName: "runner-1", runnerToken: "token").joined(separator: "\n")
        XCTAssertTrue(joined.contains("--labels sand --runnergroup 'Mac Fleet'\\''s'"))
    }

    func testScriptOmitsRunnerGroupByDefault() throws {
        let joined = try GitHubProvisioner().script(config: config(), runnerName: "runner-1", runnerToken: "token").joined(separator: "\n")
        XCTAssertFalse(joined.contains("--runnergroup"))
    }

    func testScriptUsesServerURLForRepoRunner() throws {
        let joined = try GitHubProvisioner().script(config: config(repository: "repo", serverURL: "https://acme.ghe.com"), runnerName: "runner-1", runnerToken: "token").joined(separator: "\n")
        XCTAssertTrue(joined.contains("--url https://acme.ghe.com/org/repo --name"))
        XCTAssertFalse(joined.contains("github.com"))
    }

    func testScriptUsesServerURLForOrgRunner() throws {
        let joined = try GitHubProvisioner().script(config: config(serverURL: "https://acme.ghe.com/"), runnerName: "runner-1", runnerToken: "token").joined(separator: "\n")
        XCTAssertTrue(joined.contains("--url https://acme.ghe.com/org --name"))
    }

    func testScriptUsesServerURLForGHES() throws {
        let joined = try GitHubProvisioner().script(config: config(repository: "repo", serverURL: "https://ghes.example.com:8443"), runnerName: "runner-1", runnerToken: "token").joined(separator: "\n")
        XCTAssertTrue(joined.contains("--url https://ghes.example.com:8443/org/repo --name"))
    }

    func testScriptRejectsInvalidServerURL() {
        XCTAssertThrowsError(try GitHubProvisioner().script(config: config(serverURL: "http://ghes.example.com"), runnerName: "runner-1", runnerToken: "token")) { error in
            XCTAssertEqual(error as? GitHubServerError, .invalidServerURL("http://ghes.example.com"))
        }
    }

    func testUniqueRunnerNameAppendsHexSuffix() {
        let name = GitHubProvisioner.uniqueRunnerName(base: "runner-1")
        XCTAssertNotNil(name.wholeMatch(of: /runner-1-[0-9a-f]{5}/))
    }
}
