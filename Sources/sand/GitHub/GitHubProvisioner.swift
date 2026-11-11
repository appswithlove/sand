struct GitHubProvisionerConfig: Decodable, Sendable {
    let appId: Int
    let organization: String
    let repository: String?
    let privateKeyPath: String
    let runnerName: String
    let extraLabels: [String]?
    let runnerGroup: String?
    /// Web URL of the GitHub instance. `nil` means github.com.
    let serverURL: String?
    /// Shell lines run in the VM after the runner is extracted and before `config.sh`.
    let setupCommands: [String]?

    init(
        appId: Int,
        organization: String,
        repository: String?,
        privateKeyPath: String,
        runnerName: String,
        extraLabels: [String]?,
        runnerGroup: String? = nil,
        serverURL: String? = nil,
        setupCommands: [String]? = nil
    ) {
        self.appId = appId
        self.organization = organization
        self.repository = repository
        self.privateKeyPath = privateKeyPath
        self.runnerName = runnerName
        self.extraLabels = extraLabels
        self.runnerGroup = runnerGroup
        self.serverURL = serverURL
        self.setupCommands = setupCommands
    }

    func resolvedServer() throws -> GitHubServer {
        guard let serverURL else {
            return .dotCom
        }
        guard let server = GitHubServer(string: serverURL) else {
            throw GitHubServerError.invalidServerURL(serverURL)
        }
        return server
    }
}

struct GitHubProvisioner: Sendable {
    static let tarballRemotePath = "actions-runner.tar.gz"

    static func uniqueRunnerName(base: String) -> String {
        "\(base)-\(String(format: "%05x", Int.random(in: 0..<0x100000)))"
    }

    func script(
        config: GitHubProvisionerConfig,
        runnerName: String,
        runnerToken: String
    ) throws -> [String] {
        let labels = labelsString(extraLabels: config.extraLabels)
        let url = try config.resolvedServer().runnerURL(organization: config.organization, repository: config.repository)
        let runnerGroupArgument = config.runnerGroup.map { " --runnergroup \(Self.shellQuote($0))" } ?? ""
        let extract = [
            "rm -rf ~/actions-runner && mkdir ~/actions-runner",
            "tar xzf ~/\(Self.tarballRemotePath) -C ~/actions-runner",
            "echo \"Runner extracted\""
        ]
        return extract + (config.setupCommands ?? []) + [
            "~/actions-runner/config.sh --url \(url) --name \(runnerName) --token \(runnerToken) --ephemeral --unattended --replace --labels \(labels)\(runnerGroupArgument)",
            "echo \"Runner configured, starting ~/actions-runner/run.sh\"",
            "~/actions-runner/run.sh"
        ]
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func labelsString(extraLabels: [String]?) -> String {
        var labels = ["sand"]
        if let extraLabels {
            labels.append(contentsOf: extraLabels)
        }
        return labels.joined(separator: ",")
    }
}
