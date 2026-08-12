import Foundation

struct GitHubProvisionerConfig: Decodable, Sendable {
    static let defaultRecycleAfterOffline: TimeInterval = 600

    let appId: Int
    let organization: String
    let repository: String?
    let privateKeyPath: String
    let runnerName: String
    let extraLabels: [String]?
    let runnerGroup: String?
    let recycleAfterOffline: TimeInterval

    init(
        appId: Int,
        organization: String,
        repository: String?,
        privateKeyPath: String,
        runnerName: String,
        extraLabels: [String]?,
        runnerGroup: String?,
        recycleAfterOffline: TimeInterval = Self.defaultRecycleAfterOffline
    ) {
        self.appId = appId
        self.organization = organization
        self.repository = repository
        self.privateKeyPath = privateKeyPath
        self.runnerName = runnerName
        self.extraLabels = extraLabels
        self.runnerGroup = runnerGroup
        self.recycleAfterOffline = recycleAfterOffline
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.appId = try container.decode(Int.self, forKey: .appId)
        self.organization = try container.decode(String.self, forKey: .organization)
        self.repository = try container.decodeIfPresent(String.self, forKey: .repository)
        self.privateKeyPath = try container.decode(String.self, forKey: .privateKeyPath)
        self.runnerName = try container.decode(String.self, forKey: .runnerName)
        self.extraLabels = try container.decodeIfPresent([String].self, forKey: .extraLabels)
        self.runnerGroup = try container.decodeIfPresent(String.self, forKey: .runnerGroup)
        self.recycleAfterOffline = try container.decodeIfPresent(TimeInterval.self, forKey: .recycleAfterOffline)
            ?? Self.defaultRecycleAfterOffline
    }

    private enum CodingKeys: String, CodingKey {
        case appId
        case organization
        case repository
        case privateKeyPath
        case runnerName
        case extraLabels
        case runnerGroup
        case recycleAfterOffline
    }
}

struct GitHubProvisioner: Sendable {
    static func uniqueRunnerName(base: String) -> String {
        let suffix = String(format: "%05x", Int.random(in: 0..<0x100000))
        return "\(base)-\(suffix)"
    }

    func script(config: GitHubProvisionerConfig, runnerToken: String, runnerName: String) -> [String] {
        let labels = labelsString(extraLabels: config.extraLabels)
        let url = runnerURL(organization: config.organization, repository: config.repository)
        let runnerGroupArg = config.runnerGroup.map { " --runnergroup '\($0)'" } ?? ""
        return [
            "test -f actions-runner.tar.gz || { echo 'actions-runner.tar.gz missing: host preseed did not run' >&2; exit 1; }",
            "rm -rf ~/actions-runner && mkdir ~/actions-runner",
            "tar xzf ./actions-runner.tar.gz -C ~/actions-runner",
            "echo \"Runner extracted\"",
            "~/actions-runner/config.sh --url \(url) --name \(runnerName) --token \(runnerToken) --ephemeral --unattended --replace --labels \(labels)\(runnerGroupArg)",
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
