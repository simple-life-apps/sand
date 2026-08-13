import Foundation
@testable import sand

actor ScriptedPoll {
    enum Step {
        case missing
        case online
        case onlineBusy
        case offline
        case offlineBusy
        case unrecognized
        case error
    }

    private let script: [Step]
    private let repeats: Bool
    private(set) var calls = 0

    init(_ script: [Step], repeats: Bool = true) {
        self.script = script
        self.repeats = repeats
    }

    func next() throws -> GitHubService.RunnerLookup {
        struct PollError: Error {}
        let step = repeats ? script[calls % script.count] : script[min(calls, script.count - 1)]
        calls += 1
        switch step {
        case .missing:
            return .notRegistered
        case .online:
            return .registered(GitHubService.RunnerStatus(connection: .online, busy: false))
        case .onlineBusy:
            return .registered(GitHubService.RunnerStatus(connection: .online, busy: true))
        case .offline:
            return .registered(GitHubService.RunnerStatus(connection: .offline, busy: false))
        case .offlineBusy:
            return .registered(GitHubService.RunnerStatus(connection: .offline, busy: true))
        case .unrecognized:
            return .registered(GitHubService.RunnerStatus(connection: .unrecognized("weird"), busy: false))
        case .error:
            throw PollError()
        }
    }

    @discardableResult
    func waitForCalls(atLeast target: Int, attempts: Int = 400) async -> Int {
        var remaining = attempts
        while calls < target, remaining > 0 {
            remaining -= 1
            try? await Task.sleep(for: .milliseconds(5))
        }
        return calls
    }
}

enum TestHelperError: Error {
    case invalidTokenPartsCount
    case invalidPayload
}

func writeTempFile(contents: String, suffix: String = "") throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("temp\(suffix)")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

func decodeJWTClaims(_ token: String) throws -> [String: Any] {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else {
        throw TestHelperError.invalidTokenPartsCount
    }
    let payload = String(parts[1])
    let data = try base64URLDecode(payload)
    let json = try JSONSerialization.jsonObject(with: data)
    guard let dict = json as? [String: Any] else {
        throw TestHelperError.invalidPayload
    }
    return dict
}

func base64URLDecode(_ value: String) throws -> Data {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let padding = base64.count % 4
    if padding != 0 {
        base64 += String(repeating: "=", count: 4 - padding)
    }
    guard let data = Data(base64Encoded: base64) else {
        throw NSError(domain: "base64", code: 1)
    }
    return data
}
