struct GitHubProvisionerConfig: Decodable, Sendable {
    let appId: Int
    let organization: String
    let repository: String?
    let privateKeyPath: String
    let runnerName: String
    let extraLabels: [String]?
    let runnerGroup: String?

    init(
        appId: Int,
        organization: String,
        repository: String?,
        privateKeyPath: String,
        runnerName: String,
        extraLabels: [String]?,
        runnerGroup: String?
    ) {
        self.appId = appId
        self.organization = organization
        self.repository = repository
        self.privateKeyPath = privateKeyPath
        self.runnerName = runnerName
        self.extraLabels = extraLabels
        self.runnerGroup = runnerGroup
    }
}

struct GitHubProvisioner: Sendable {
    func script(config: GitHubProvisionerConfig, runnerToken: String) -> [String] {
        let labels = labelsString(extraLabels: config.extraLabels)
        let url = runnerURL(organization: config.organization, repository: config.repository)
        let runnerGroupArg = config.runnerGroup.map { " --runnergroup '\($0)'" } ?? ""
        return [
            "test -f actions-runner.tar.gz || { echo 'actions-runner.tar.gz missing: host preseed did not run' >&2; exit 1; }",
            "rm -rf ~/actions-runner && mkdir ~/actions-runner",
            "tar xzf ./actions-runner.tar.gz -C ~/actions-runner",
            "echo \"Runner extracted\"",
            "~/actions-runner/config.sh --url \(url) --name \(config.runnerName) --token \(runnerToken) --ephemeral --unattended --replace --labels \(labels)\(runnerGroupArg)",
            "echo \"Runner configured, starting ~/actions-runner/run.sh\"",
            "~/actions-runner/run.sh"
        ]
    }

    private func labelsString(extraLabels: [String]?) -> String {
        var labels = ["sand"]
        if let extraLabels {
            labels.append(contentsOf: extraLabels)
        }
        return labels.joined(separator: ",")
    }

    static func runnerAssetName(os: String, arch: String, version: String) -> String? {
        let runnerOs: String
        switch os {
        case "Darwin":
            runnerOs = "osx"
        case "Linux":
            runnerOs = "linux"
        default:
            return nil
        }
        let runnerArch: String
        switch arch {
        case "x86_64", "amd64":
            runnerArch = "x64"
        case "arm64", "aarch64":
            runnerArch = "arm64"
        case "armv7l", "armv6l":
            runnerArch = "arm"
        default:
            return nil
        }
        return "actions-runner-\(runnerOs)-\(runnerArch)-\(version).tar.gz"
    }

    private func runnerURL(organization: String, repository: String?) -> String {
        if let repository {
            return "https://github.com/\(organization)/\(repository)"
        }
        return "https://github.com/\(organization)"
    }
}
