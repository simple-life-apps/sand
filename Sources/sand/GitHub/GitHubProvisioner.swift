import Foundation

enum OfflineRecycling: Equatable, Sendable {
    case disabled
    case after(Duration)

    static let `default` = OfflineRecycling.after(.seconds(600))

    enum ParseError: Error, CustomStringConvertible {
        case notFinite
        case negative
        case exceedsOneYear

        var description: String {
            switch self {
            case .notFinite:
                return "recycleAfterOffline must be a finite number of seconds."
            case .negative:
                return "recycleAfterOffline must be >= 0 (0 disables offline recycling)."
            case .exceedsOneYear:
                return "recycleAfterOffline must be at most 31536000 seconds (one year)."
            }
        }
    }

    init(seconds: TimeInterval) throws {
        guard seconds.isFinite else { throw ParseError.notFinite }
        guard seconds >= 0 else { throw ParseError.negative }
        guard seconds <= 31_536_000 else { throw ParseError.exceedsOneYear }
        self = seconds == 0 ? .disabled : .after(.seconds(seconds))
    }
}

struct GitHubProvisionerConfig: Decodable, Sendable {
    let appId: Int
    let organization: String
    let repository: String?
    let privateKeyPath: String
    let runnerName: String
    let extraLabels: [String]?
    let runnerGroup: String?
    let recycleAfterOffline: OfflineRecycling

    init(
        appId: Int,
        organization: String,
        repository: String?,
        privateKeyPath: String,
        runnerName: String,
        extraLabels: [String]?,
        runnerGroup: String?,
        recycleAfterOffline: OfflineRecycling = .default
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
        if let seconds = try container.decodeIfPresent(TimeInterval.self, forKey: .recycleAfterOffline) {
            do {
                self.recycleAfterOffline = try OfflineRecycling(seconds: seconds)
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .recycleAfterOffline,
                    in: container,
                    debugDescription: String(describing: error)
                )
            }
        } else {
            self.recycleAfterOffline = .default
        }
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

struct ProvisionerScript {
    let setup: [String]
    let run: String
}

struct GitHubProvisioner: Sendable {
    static func uniqueRunnerName(base: String) -> String {
        let suffix = String(format: "%05x", Int.random(in: 0..<0x100000))
        return "\(base)-\(suffix)"
    }

    func script(config: GitHubProvisionerConfig, runnerToken: String, runnerName: String) -> ProvisionerScript {
        let labels = labelsString(extraLabels: config.extraLabels)
        let url = runnerURL(organization: config.organization, repository: config.repository)
        let runnerGroupArg = config.runnerGroup.map { " --runnergroup '\($0)'" } ?? ""
        return ProvisionerScript(
            setup: [
                "test -f actions-runner.tar.gz || { echo 'actions-runner.tar.gz missing: host preseed did not run' >&2; exit 1; }",
                "rm -rf ~/actions-runner && mkdir ~/actions-runner",
                "tar xzf ./actions-runner.tar.gz -C ~/actions-runner",
                "echo \"Runner extracted\"",
                "~/actions-runner/config.sh --url \(url) --name \(runnerName) --token \(runnerToken) --ephemeral --unattended --replace --labels \(labels)\(runnerGroupArg)",
                "echo \"Runner configured, starting ~/actions-runner/run.sh\""
            ],
            run: "~/actions-runner/run.sh"
        )
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
