# Runner Offline Recycling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** sand recycles a VM whose GitHub Actions runner has been continuously offline on GitHub longer than a threshold, and hardens the SSH health check against unbounded stalls.

**Architecture:** A new offline-monitor task (started per boot, `github` provisioner only) polls the GitHub runners API every 60s from the host, feeds observations into a pure `OfflineTimer` state machine (accumulated confirmed-offline time on a monotonic clock), and on threshold recycles the VM through the same interrupt path a failed health check uses (`markFailed` → terminate provisioner → `scheduleRestart`). The existing `HealthCheckState` failure channel is generalized to carry a failure kind so the restart reason distinguishes `runnerOffline` from `healthCheckFailed`. GitHub API polling reuses a cached installation token with expiry-aware refresh.

**Tech Stack:** Swift 6 / SwiftPM, Swift Testing (`@Test`/`#expect`) for new tests, XCTest for extending existing suites (match whichever framework the file already uses), Yams-decoded YAML config.

**Spec:** `docs/plans/runner-self-healing-spec.md` (same branch). Read it before starting.

## Global Constraints

- Config key: `recycleAfterOffline` (seconds) on the github provisioner config; default `600`; `0` disables the monitor entirely; negative values are a config validation error.
- Poll interval is fixed at 60s (constant, not configurable).
- A runner GitHub reports `busy` is never recycled; `busy` or `online` resets the offline timer.
- GitHub API errors = status *unknown*: the timer must neither advance nor reset; unknown intervals contribute zero accumulated offline time (monotonic clock).
- The offline outcome must be recorded (`markFailed`) *before* the provisioner process is terminated.
- A cancelled monitor must be awaited out (`await task.value`) before the boot's cleanup completes, so no stale poll can act on a successor boot.
- Token cache: refresh before `expires_at` (60s safety margin) or once on 401 then retry; steady-state = one GET per poll.
- SSH options: `ConnectTimeout=10`, `ServerAliveInterval=15`, `ServerAliveCountMax=4` on all sshpass invocations.
- Commit after every task (local commits; pre-commit hook runs `swift test` automatically — a commit that succeeds is a green test run).
- Build with `swift build`; run tests with `swift test 2>&1 | tee $TMPDIR/swift-test.log` and inspect the log file rather than re-running.

---

### Task 1: SSH client timeouts

**Files:**
- Modify: `Sources/sand/SSHClient.swift`
- Test: `Tests/sandTests/SSHClientTests.swift`

**Interfaces:**
- Produces: every `sshpass` invocation (`exec`, `start`, `copy`) carries `-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4`. No signature changes.

- [ ] **Step 1: Update the existing test to expect the new options**

In `Tests/sandTests/SSHClientTests.swift`, `testStartBuildsSSHCommand`, replace the expected arguments array with:

```swift
arguments: [
    "-p", "pw",
    "ssh",
    "-o", "PreferredAuthentications=password",
    "-o", "PubkeyAuthentication=no",
    "-o", "IdentitiesOnly=yes",
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=4",
    "-p", "2222",
    "admin@10.0.0.1",
    "/bin/bash -lc 'echo hi'"
],
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SSHClientTests 2>&1 | tee $TMPDIR/t1.log`
Expected: FAIL (argument arrays differ — missing the three new `-o` options).

- [ ] **Step 3: Implement**

In `Sources/sand/SSHClient.swift`, add a shared option list and use it in all three methods. The three methods currently repeat the same six `-o` pairs; replace the repetition:

```swift
struct SSHClient {
    let processRunner: ProcessRunning
    let host: String
    let config: Config.SSH

    private static let commonOptions: [String] = [
        "-o", "PreferredAuthentications=password",
        "-o", "PubkeyAuthentication=no",
        "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=4"
    ]
```

`exec` and `start` build arguments as:

```swift
        return try await processRunner.run(
            executable: "sshpass",
            arguments: ["-p", config.password, "ssh"]
                + Self.commonOptions
                + ["-p", String(config.port), "\(config.user)@\(host)", remote],
            wait: true
        )
```

(`start` identically but via `processRunner.start` and without `wait:`.) `copy` keeps `scp` and its `-P` port flag:

```swift
        return try await processRunner.run(
            executable: "sshpass",
            arguments: ["-p", config.password, "scp"]
                + Self.commonOptions
                + ["-P", String(config.port), localPath, "\(config.user)@\(host):\(remotePath)"],
            wait: true
        )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SSHClientTests 2>&1 | tee $TMPDIR/t1.log`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/sand/SSHClient.swift Tests/sandTests/SSHClientTests.swift
git commit -m "Bound SSH probe stalls with ConnectTimeout and ServerAlive options"
```

---

### Task 2: Health check loop pacing and IP-resolve visibility

**Files:**
- Modify: `Sources/sand/Runner.swift` (the health check loop inside `startHealthCheck`, currently lines ~583-615)

**Interfaces:**
- Consumes: nothing new.
- Produces: no API change. Behavior: an IP-resolution failure logs at `.warning` and still sleeps `healthCheck.interval` before the next tick (today it `continue`s past the sleep and logs at `.debug`).

There is no existing test harness for this loop (it drives `tart`/`ssh` subprocesses); this task is verified by build + full existing suite via the commit hook.

- [ ] **Step 1: Restructure the probe block**

In `startHealthCheck`'s `while !Task.isCancelled` loop, the second `do` block currently begins:

```swift
                do {
                    guard let ip = await resolveHealthCheckIP(name: vmName, interval: healthCheck.interval) else {
                        self.logger.debug("healthCheck failed to resolve IP; retrying")
                        continue
                    }
                    self.logger.debug("healthCheck resolved IP: \(ip)")
```

Replace the `guard`/`continue` with an `if let` so control always falls through to the interval sleep at the bottom of the loop, and raise the log level:

```swift
                do {
                    if let ip = await resolveHealthCheckIP(name: vmName, interval: healthCheck.interval) {
                        self.logger.debug("healthCheck resolved IP: \(ip)")
                        let probe = SSHClient(processRunner: tart.processRunner, host: ip, config: ssh)
                        let probeCommand = wrapHealthCheckCommand(healthCheck.command)
                        let result = try await probe.exec(command: probeCommand)
                        let output = result?.stdout ?? ""
                        let exitCode = parseHealthCheckExitCode(output: output) ?? 1
                        self.logger.debug("healthCheck exit code \(exitCode)")
                        if exitCode == 0 {
                            sawSuccess = true
                            self.logger.debug("healthCheck success")
                        } else {
                            let filteredOutput = stripHealthCheckMarker(output: output)
                            let outputLabel = healthCheckLabel.isEmpty ? "healthCheck output" : "healthCheck output (\(healthCheckLabel))"
                            logIfNonEmpty(label: outputLabel, text: filteredOutput)
                            let message = "exit code \(exitCode)"
                            let inStartupGrace = !sawSuccess && Date().timeIntervalSince(activationTime) < startupGrace
                            if inStartupGrace {
                                logger.warning("\(healthCheckDescriptor) failed with \(message) during startup grace, retrying")
                            } else {
                                logger.warning("\(healthCheckDescriptor) failed with \(message), marking healthCheck failed")
                                await state.markFailed(message: message)
                                await control.terminateProvisioning()
                                return
                            }
                        }
                    } else {
                        logger.warning("healthCheck could not resolve VM IP; retrying next interval")
                    }
                } catch {
                    logger.warning("\(healthCheckDescriptor) error (will retry): \(String(describing: error))")
                }
```

The body inside `if let ip` is the existing code unchanged, only re-indented; the only new lines are the `if let`/`else` and the warning. (Note: Task 7 later changes `state.markFailed(message: message)` — if Task 7 is already done in your copy, the call is `state.markFailed(.healthCheck(message))`.)

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tee $TMPDIR/t2.log`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/sand/Runner.swift
git commit -m "Health check: keep interval pacing and log IP-resolve failures visibly"
```

---

### Task 3: OfflineTimer state machine

**Files:**
- Create: `Sources/sand/OfflineTimer.swift`
- Create: `Tests/sandTests/OfflineTimerTests.swift`

**Interfaces:**
- Produces:
  - `struct OfflineTimer` with `init(threshold: Duration)`.
  - `enum OfflineTimer.Signal { case healthy, offline, unknown }`
  - `mutating func observe(_ signal: Signal, at now: ContinuousClock.Instant) -> Bool` — returns `true` when accumulated confirmed-offline time has reached the threshold.

Semantics (from the spec): the threshold is *accumulated confirmed-offline observation time* on a monotonic clock. Time only accumulates between two consecutive `offline` observations. `healthy` resets accumulation to zero. `unknown` contributes zero and breaks the offline chain (the gap around it is not counted) but does not reset what was already accumulated.

- [ ] **Step 1: Write the failing tests**

Create `Tests/sandTests/OfflineTimerTests.swift`:

```swift
import Testing
@testable import sand

struct OfflineTimerTests {
    private let start = ContinuousClock().now

    @Test func firesAfterContinuousOfflineReachesThreshold() {
        var timer = OfflineTimer(threshold: .seconds(120))
        #expect(timer.observe(.offline, at: start) == false)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(60))) == false)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(120))) == true)
    }

    @Test func healthyResetsAccumulation() {
        var timer = OfflineTimer(threshold: .seconds(120))
        _ = timer.observe(.offline, at: start)
        _ = timer.observe(.offline, at: start.advanced(by: .seconds(100)))
        _ = timer.observe(.healthy, at: start.advanced(by: .seconds(160)))
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(220))) == false)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(280))) == false)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(340))) == true)
    }

    @Test func unknownIntervalAddsZeroAccumulatedTime() {
        var timer = OfflineTimer(threshold: .seconds(120))
        _ = timer.observe(.offline, at: start)
        _ = timer.observe(.offline, at: start.advanced(by: .seconds(60)))
        // Hours of unknown must not advance the timer...
        _ = timer.observe(.unknown, at: start.advanced(by: .seconds(3600)))
        // ...and the first offline after unknown must not count the gap either.
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(7200))) == false)
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(7230))) == false)
        // 60s (before unknown) + 30s + 30s = 120s accumulated -> fires.
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(7260))) == true)
    }

    @Test func unknownDoesNotResetAccumulation() {
        var timer = OfflineTimer(threshold: .seconds(90))
        _ = timer.observe(.offline, at: start)
        _ = timer.observe(.offline, at: start.advanced(by: .seconds(60)))
        _ = timer.observe(.unknown, at: start.advanced(by: .seconds(120)))
        _ = timer.observe(.offline, at: start.advanced(by: .seconds(180)))
        #expect(timer.observe(.offline, at: start.advanced(by: .seconds(210))) == true)
    }

    @Test func zeroThresholdFiresOnFirstOffline() {
        var timer = OfflineTimer(threshold: .zero)
        #expect(timer.observe(.offline, at: start) == true)
    }

    @Test func healthyNeverFires() {
        var timer = OfflineTimer(threshold: .zero)
        #expect(timer.observe(.healthy, at: start) == false)
        #expect(timer.observe(.unknown, at: start.advanced(by: .seconds(60))) == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OfflineTimerTests 2>&1 | tee $TMPDIR/t3.log`
Expected: FAIL to build — `OfflineTimer` not defined.

- [ ] **Step 3: Implement**

Create `Sources/sand/OfflineTimer.swift`:

```swift
struct OfflineTimer {
    enum Signal {
        case healthy
        case offline
        case unknown
    }

    let threshold: Duration
    private var accumulated: Duration = .zero
    private var lastOffline: ContinuousClock.Instant?

    init(threshold: Duration) {
        self.threshold = threshold
    }

    mutating func observe(_ signal: Signal, at now: ContinuousClock.Instant) -> Bool {
        switch signal {
        case .healthy:
            accumulated = .zero
            lastOffline = nil
            return false
        case .unknown:
            lastOffline = nil
            return false
        case .offline:
            if let lastOffline, now > lastOffline {
                accumulated += lastOffline.duration(to: now)
            }
            lastOffline = now
            return accumulated >= threshold
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter OfflineTimerTests 2>&1 | tee $TMPDIR/t3.log`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/sand/OfflineTimer.swift Tests/sandTests/OfflineTimerTests.swift
git commit -m "Add OfflineTimer accumulating confirmed-offline time"
```

---

### Task 4: GitHubService.runnerStatus

**Files:**
- Modify: `Sources/sand/GitHub/GitHubService.swift`
- Test: `Tests/sandTests/GitHubServiceTests.swift`

**Interfaces:**
- Consumes: existing `runnersPath()`, `request(path:method:token:)`, `installationID()`, `installationAccessToken(installationId:)`.
- Produces:
  - `struct GitHubService.RunnerStatus: Equatable, Sendable { let online: Bool; let busy: Bool }`
  - `func runnerStatus(named name: String) async throws -> RunnerStatus?` — `nil` means not registered on GitHub. Token caching is Task 5; in this task the method authenticates the same way `deleteRunner` does.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/sandTests/GitHubServiceTests.swift` (XCTest — match the file):

```swift
    func testRunnerStatusOnlineBusy() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[{\"id\":42,\"name\":\"r-a3f9c\",\"status\":\"online\",\"busy\":true}]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let status = try await service.runnerStatus(named: "r-a3f9c")
        XCTAssertEqual(status, GitHubService.RunnerStatus(online: true, busy: true))
        let listRequest = session.requests.last
        XCTAssertEqual(listRequest?.url?.path, "/orgs/org/actions/runners")
        XCTAssertEqual(listRequest?.url?.query, "name=r-a3f9c")
    }

    func testRunnerStatusOffline() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[{\"id\":42,\"name\":\"r-a3f9c\",\"status\":\"offline\",\"busy\":false}]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let status = try await service.runnerStatus(named: "r-a3f9c")
        XCTAssertEqual(status, GitHubService.RunnerStatus(online: false, busy: false))
    }

    func testRunnerStatusNotRegistered() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        let status = try await service.runnerStatus(named: "r-a3f9c")
        XCTAssertNil(status)
    }
```

Note: the `access_tokens` stubs already include `expires_at` so these tests survive Task 5 unchanged. GitHub's real payload includes it too.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GitHubServiceTests 2>&1 | tee $TMPDIR/t4.log`
Expected: FAIL to build — `runnerStatus`/`RunnerStatus` not defined.

- [ ] **Step 3: Implement**

In `Sources/sand/GitHub/GitHubService.swift`:

Extend the runners-list DTO with the two optional fields (optional so existing `deleteRunner` fixtures without them keep decoding):

```swift
    struct RunnersListResponse: Decodable {
        struct Runner: Decodable {
            let id: Int
            let name: String
            let status: String?
            let busy: Bool?
        }
        let runners: [Runner]
    }
```

Add the status type and method (place next to `deleteRunner`):

```swift
    struct RunnerStatus: Equatable, Sendable {
        let online: Bool
        let busy: Bool
    }

    func runnerStatus(named name: String) async throws -> RunnerStatus? {
        let installationId = try await installationID()
        let accessToken = try await installationAccessToken(installationId: installationId)
        return try await fetchRunnerStatus(named: name, token: accessToken)
    }

    private func fetchRunnerStatus(named name: String, token: String) async throws -> RunnerStatus? {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let list: RunnersListResponse = try await request(
            path: "\(runnersPath())?name=\(encodedName)",
            method: "GET",
            token: token
        )
        guard let runner = list.runners.first(where: { $0.name == name }) else {
            return nil
        }
        return RunnerStatus(online: runner.status == "online", busy: runner.busy ?? false)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GitHubServiceTests 2>&1 | tee $TMPDIR/t4.log`
Expected: PASS (7 tests: 4 existing + 3 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/sand/GitHub/GitHubService.swift Tests/sandTests/GitHubServiceTests.swift
git commit -m "Add GitHubService.runnerStatus(named:) with status/busy decoding"
```

---

### Task 5: Expiry-aware installation token cache

**Files:**
- Modify: `Sources/sand/GitHub/GitHubService.swift`
- Test: `Tests/sandTests/GitHubServiceTests.swift`

**Interfaces:**
- Consumes: `fetchRunnerStatus(named:token:)` from Task 4.
- Produces: `runnerStatus(named:)` now authenticates via a shared `GitHubTokenCache` actor: installation id fetched once, installation token reused until 60s before `expires_at`, invalidated and re-minted once on HTTP 401 (the status fetch is then retried once). `runnerRegistrationToken()` and `deleteRunner(named:)` are intentionally left on their existing per-call auth path (they run once per boot).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/sandTests/GitHubServiceTests.swift`:

```swift
    func testRunnerStatusReusesInstallationToken() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        _ = try await service.runnerStatus(named: "r-a3f9c")
        _ = try await service.runnerStatus(named: "r-a3f9c")
        _ = try await service.runnerStatus(named: "r-a3f9c")
        let authRequests = session.requests.filter { $0.url?.path.contains("access_tokens") == true }
        let installationRequests = session.requests.filter { $0.url?.path == "/orgs/org/installation" }
        XCTAssertEqual(authRequests.count, 1)
        XCTAssertEqual(installationRequests.count, 1)
        let statusRequests = session.requests.filter { $0.url?.path == "/orgs/org/actions/runners" }
        XCTAssertEqual(statusRequests.count, 3)
    }

    func testRunnerStatusRefreshesExpiredToken() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        // Already-expired token: the second call must mint a fresh one.
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2020-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"runners\":[]}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        _ = try await service.runnerStatus(named: "r-a3f9c")
        _ = try await service.runnerStatus(named: "r-a3f9c")
        let authRequests = session.requests.filter { $0.url?.path.contains("access_tokens") == true }
        XCTAssertEqual(authRequests.count, 2)
    }

    func testRunnerStatusRetriesOnceAfter401() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\",\"expires_at\":\"2030-01-01T00:00:00Z\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners"] = (Data("{\"message\":\"Bad credentials\"}".utf8), 401)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: nil)
        // Prime the cache with the (about-to-be-rejected) token.
        do {
            _ = try await service.runnerStatus(named: "r-a3f9c")
            XCTFail("expected 401 to propagate after one retry")
        } catch {
            // expected: still 401 after retry
        }
        let authRequests = session.requests.filter { $0.url?.path.contains("access_tokens") == true }
        let statusRequests = session.requests.filter { $0.url?.path == "/orgs/org/actions/runners" }
        XCTAssertEqual(authRequests.count, 2, "401 must invalidate the cached token and mint once more")
        XCTAssertEqual(statusRequests.count, 2, "the status fetch is retried exactly once")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GitHubServiceTests 2>&1 | tee $TMPDIR/t5.log`
Expected: `testRunnerStatusReusesInstallationToken` FAILS (3 auth requests, not 1); the 401 test FAILS (1 auth request, not 2). (`testRunnerStatusRefreshesExpiredToken` may incidentally pass before the change since every call re-mints; that is fine.)

- [ ] **Step 3: Implement**

In `Sources/sand/GitHub/GitHubService.swift`:

Add `expiresAt` to the token DTO (decoded from `expires_at` via the existing `convertFromSnakeCase` strategy plus an ISO8601 date strategy):

```swift
    struct AccessTokenResponse: Decodable {
        let token: String
        let expiresAt: Date
    }
```

In the generic `request` method, add the date strategy:

```swift
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
```

Add the cache actor (same file, below the service struct):

```swift
actor GitHubTokenCache {
    private var installationId: Int?
    private var token: String?
    private var expiresAt: Date?

    func cachedInstallationId() -> Int? {
        installationId
    }

    func store(installationId: Int) {
        self.installationId = installationId
    }

    func validToken(now: Date) -> String? {
        guard let token, let expiresAt, now < expiresAt.addingTimeInterval(-60) else {
            return nil
        }
        return token
    }

    func store(token: String, expiresAt: Date) {
        self.token = token
        self.expiresAt = expiresAt
    }

    func invalidateToken() {
        token = nil
        expiresAt = nil
    }
}
```

Give `GitHubService` the cache (a `let` reference on the struct; copies share it — `Sand` builds one service per runner):

```swift
    let auth: GitHubAuthenticating
    let session: URLSessionProtocol
    let organization: String
    let repository: String?
    let baseURL = URL(string: "https://api.github.com")!
    let tokenCache = GitHubTokenCache()
```

Rewrite `runnerStatus` to use it, with the single 401 retry:

```swift
    func runnerStatus(named name: String) async throws -> RunnerStatus? {
        do {
            return try await fetchRunnerStatus(named: name, token: cachedInstallationToken())
        } catch let GitHubServiceError.httpError(status, _) where status == 401 {
            await tokenCache.invalidateToken()
            return try await fetchRunnerStatus(named: name, token: cachedInstallationToken())
        }
    }

    private func cachedInstallationToken() async throws -> String {
        if let token = await tokenCache.validToken(now: Date()) {
            return token
        }
        let installationId: Int
        if let cached = await tokenCache.cachedInstallationId() {
            installationId = cached
        } else {
            installationId = try await installationID()
            await tokenCache.store(installationId: installationId)
        }
        let jwt = try auth.token(now: Date())
        let response: AccessTokenResponse = try await request(
            path: "/app/installations/\(installationId)/access_tokens",
            method: "POST",
            token: jwt
        )
        await tokenCache.store(token: response.token, expiresAt: response.expiresAt)
        return response.token
    }
```

`installationAccessToken(installationId:)` remains for `runnerRegistrationToken`/`deleteRunner`; those paths still decode `AccessTokenResponse`, so their test stubs must also gain `expires_at` — update the four existing `access_tokens` stub bodies in `GitHubServiceTests` from `{"token":"access"}` to `{"token":"access","expires_at":"2030-01-01T00:00:00Z"}` (and `testRepoLevelPaths` likewise).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GitHubServiceTests 2>&1 | tee $TMPDIR/t5.log`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/sand/GitHub/GitHubService.swift Tests/sandTests/GitHubServiceTests.swift
git commit -m "Cache installation tokens with expiry refresh and 401 retry for status polls"
```

---

### Task 6: recycleAfterOffline config key

**Files:**
- Modify: `Sources/sand/GitHub/GitHubProvisioner.swift` (`GitHubProvisionerConfig`)
- Modify: `Sources/sand/Config.swift` (`expanded()` at ~line 437)
- Modify: `Sources/sand/ConfigValidator.swift` (github section, ~line 147)
- Modify: `fixtures/sample_full_config.yml`
- Test: `Tests/sandTests/ConfigTests.swift`, `Tests/sandTests/ConfigValidatorTests.swift`

**Interfaces:**
- Produces: `GitHubProvisionerConfig.recycleAfterOffline: TimeInterval` — non-optional, default `600` (both in the memberwise init and when the YAML key is absent). Negative → validation error. `0` means disabled (consumed by Task 8).

- [ ] **Step 1: Write the failing tests**

In `Tests/sandTests/ConfigTests.swift` (XCTest — match the file), add:

```swift
    func testGitHubProvisionerRecycleAfterOfflineDefault() throws {
        let yaml = """
        runners:
          - name: runner-1
            vm:
              source:
                type: oci
                image: ghcr.io/acme/vm:latest
            provisioner:
              type: github
              config:
                appId: 42
                organization: acme
                privateKeyPath: ~/key.pem
                runnerName: runner-1
        """
        let url = try writeTempFile(contents: yaml)
        let config = try Config.load(path: url.path)
        XCTAssertEqual(config.runners.first?.provisioner.github?.recycleAfterOffline, 600)
    }

    func testGitHubProvisionerRecycleAfterOfflineExplicit() throws {
        let yaml = """
        runners:
          - name: runner-1
            vm:
              source:
                type: oci
                image: ghcr.io/acme/vm:latest
            provisioner:
              type: github
              config:
                appId: 42
                organization: acme
                privateKeyPath: ~/key.pem
                runnerName: runner-1
                recycleAfterOffline: 0
        """
        let url = try writeTempFile(contents: yaml)
        let config = try Config.load(path: url.path)
        XCTAssertEqual(config.runners.first?.provisioner.github?.recycleAfterOffline, 0)
    }
```

In `Tests/sandTests/ConfigValidatorTests.swift`, add (this file builds `Config` values programmatically; `writeTempFile(contents:suffix:)` is an existing helper there):

```swift
    func testNegativeRecycleAfterOfflineIsRejected() throws {
        let keyURL = try writeTempFile(contents: "key", suffix: ".pem")
        let vm = Config.VM(
            source: Config.VMSource(type: .oci, image: "ghcr.io/acme/vm:latest", path: nil),
            hardware: nil,
            mounts: [],
            cache: Config.Cache(hostPath: "/tmp/sand-cache", name: nil),
            run: .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let github = GitHubProvisionerConfig(
            appId: 1,
            organization: "acme",
            repository: nil,
            privateKeyPath: keyURL.path,
            runnerName: "runner-1",
            extraLabels: nil,
            runnerGroup: nil,
            recycleAfterOffline: -1
        )
        let runner = Config.RunnerConfig(
            name: "runner-1",
            vm: vm,
            provisioner: Config.Provisioner(type: .github, script: nil, github: github),
            preRun: nil,
            postRun: nil,
            stopAfter: 1,
            healthCheck: Config.HealthCheck(command: "true")
        )
        let config = Config(runners: [runner])
        let issues = ConfigValidator().validate(config)
        XCTAssertTrue(issues.contains { $0.severity == .error && $0.message == "provisioner.config.recycleAfterOffline must be >= 0 (0 disables offline recycling)." })
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "ConfigTests|ConfigValidatorTests" 2>&1 | tee $TMPDIR/t6.log`
Expected: FAIL to build — `recycleAfterOffline` not a member.

- [ ] **Step 3: Implement**

`Sources/sand/GitHub/GitHubProvisioner.swift` — add the stored property, default in the memberwise init, and a custom `init(from:)` (needed because the property is non-optional with a default):

```swift
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
```

`Sources/sand/Config.swift`, `expanded()` — pass the field through:

```swift
            let expanded = GitHubProvisionerConfig(
                appId: github.appId,
                organization: github.organization,
                repository: github.repository,
                privateKeyPath: Config.expandPath(github.privateKeyPath),
                runnerName: github.runnerName,
                extraLabels: github.extraLabels,
                runnerGroup: github.runnerGroup,
                recycleAfterOffline: github.recycleAfterOffline
            )
```

`Sources/sand/ConfigValidator.swift`, inside the `.github` case after the `runnerGroup` checks:

```swift
            if github.recycleAfterOffline < 0 {
                issues.append(.init(severity: .error, message: "provisioner.config.recycleAfterOffline must be >= 0 (0 disables offline recycling)."))
            }
```

`fixtures/sample_full_config.yml` — in the `runner-2` github provisioner config block, after `runnerGroup: null` add:

```yaml
        recycleAfterOffline: 600
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "ConfigTests|ConfigValidatorTests" 2>&1 | tee $TMPDIR/t6.log`
Expected: PASS, including all pre-existing tests (the memberwise-init default keeps existing constructions compiling).

- [ ] **Step 5: Commit**

```bash
git add Sources/sand/GitHub/GitHubProvisioner.swift Sources/sand/Config.swift Sources/sand/ConfigValidator.swift fixtures/sample_full_config.yml Tests/sandTests/ConfigTests.swift Tests/sandTests/ConfigValidatorTests.swift
git commit -m "Add recycleAfterOffline config key for github provisioner"
```

---

### Task 7: Generalize the monitor failure channel

**Files:**
- Modify: `Sources/sand/RestartBackoff.swift` (`RestartReason`)
- Modify: `Sources/sand/Runner.swift` (`HealthCheckState`, `ProvisionerOutcome`, all `.healthCheckFailed` outcome call sites, `handleStageFailure`, `startHealthCheck`'s `markFailed` call, `provisionerOutcomeLabel`)
- Test: `Tests/sandTests/RestartBackoffTests.swift`

**Interfaces:**
- Consumes: nothing from other tasks (independent of Tasks 3-6).
- Produces:
  - `enum MonitorFailure: Sendable, Equatable { case healthCheck(String); case runnerOffline(String) }` (top level in `Runner.swift`, near `HealthCheckState`).
  - `RestartReason.runnerOffline(String)` with description `"runner offline: <message>"`.
  - `HealthCheckState.markFailed(_ failure: MonitorFailure)`, `func failure() -> MonitorFailure?`, `waitForFailure() async throws -> MonitorFailure` (replacing the `String`-based API).
  - `ProvisionerOutcome.monitorFailed(MonitorFailure)` and `ProvisionerSequenceOutcome.monitorFailed(MonitorFailure)` (each replacing its `.healthCheckFailed(String)` case; both enums are private in `Runner.swift` at ~line 627).
  - `Runner.restartReason(for: MonitorFailure) -> RestartReason` private helper. Task 8's monitor calls `markFailed(.runnerOffline(message))`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/sandTests/RestartBackoffTests.swift` (XCTest):

```swift
    func testRunnerOfflineReasonDescriptionAndEquality() {
        let reason = RestartReason.runnerOffline("runner r-1 offline on GitHub for 600s+")
        XCTAssertEqual(String(describing: reason), "runner offline: runner r-1 offline on GitHub for 600s+")
        XCTAssertNotEqual(reason, RestartReason.healthCheckFailed("runner r-1 offline on GitHub for 600s+"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RestartBackoffTests 2>&1 | tee $TMPDIR/t7.log`
Expected: FAIL to build — no `runnerOffline` case.

- [ ] **Step 3: Implement**

`Sources/sand/RestartBackoff.swift` — add the case:

```swift
enum RestartReason: Equatable, CustomStringConvertible {
    case healthCheckFailed(String)
    case runnerOffline(String)
    case ipNotReady
    case sshNotReady
    case stageFailed(String)
    case provisionerExited

    var description: String {
        switch self {
        case let .healthCheckFailed(message):
            return "healthcheck failed: \(message)"
        case let .runnerOffline(message):
            return "runner offline: \(message)"
        case .ipNotReady:
            return "ip not ready"
        case .sshNotReady:
            return "ssh not ready"
        case let .stageFailed(stage):
            return "\(stage) failed"
        case .provisionerExited:
            return "provisioner exited"
        }
    }
}
```

`Sources/sand/Runner.swift`:

Add the failure type (above `private actor HealthCheckState` at the bottom of the file):

```swift
enum MonitorFailure: Sendable, Equatable {
    case healthCheck(String)
    case runnerOffline(String)

    var message: String {
        switch self {
        case let .healthCheck(message), let .runnerOffline(message):
            return message
        }
    }
}
```

Rework `HealthCheckState` storage from `String` to `MonitorFailure` (mechanical: `failureMessageStorage: String?` → `failureStorage: MonitorFailure?`; `markFailed(message: String)` → `markFailed(_ failure: MonitorFailure)`; `failureMessage() -> String?` → `failure() -> MonitorFailure?`; `waitForFailure() async throws -> String` → `-> MonitorFailure`; the waiters dictionary becomes `[UUID: CheckedContinuation<MonitorFailure, Error>]`).

In both `ProvisionerOutcome` (~line 627) and `ProvisionerSequenceOutcome` (~line 633), replace `case healthCheckFailed(String)` with:

```swift
        case monitorFailed(MonitorFailure)
```

and in `awaitProvisionerCommand` the waiting child becomes:

```swift
            group.addTask {
                do {
                    let failure = try await healthCheckState.waitForFailure()
                    return .monitorFailed(failure)
                } catch is CancellationError {
                    return nil
                } catch {
                    return .failed(error)
                }
            }
```

Add the private helpers to `Runner`:

```swift
    private func restartReason(for failure: MonitorFailure) -> RestartReason {
        switch failure {
        case let .healthCheck(message):
            return .healthCheckFailed(message)
        case let .runnerOffline(message):
            return .runnerOffline(message)
        }
    }
```

Update every call site (all in `Runner.swift`; search for `healthCheckFailed` and `failureMessage`):

- Script-provisioner outcome switch (~line 211) and github outcome switch (~line 256):

```swift
                case let .monitorFailed(failure):
                    await scheduleRestart(reason: restartReason(for: failure))
                    await stopHealthCheck(healthCheckTask)
                    await shutdownCoordinator.cleanup(reason: String(describing: restartReason(for: failure)))
                    return
```

- `runProvisionerCommands`' pass-through case (~line 651): `case let .monitorFailed(failure): return .monitorFailed(failure)`.
- The provisioner-command wait log/termination site (~line 694):

```swift
                case let .monitorFailed(failure):
                    logger.warning("monitor failed; terminating provisioner command wait: \(failure.message)")
```

(keep the subsequent termination/return flow, returning `.monitorFailed(failure)`).
- `handleStageFailure` (~line 941):

```swift
        if let healthCheckState, let failure = await healthCheckState.failure() {
            logger.debug("\(stage) failed while monitor already failed: \(failure.message)")
            await scheduleRestart(reason: restartReason(for: failure))
            return true
        }
```

- Post-run final check (~line 294):

```swift
        if let failure = await healthCheckState.failure() {
            await scheduleRestart(reason: restartReason(for: failure))
            await stopHealthCheck(healthCheckTask)
            await shutdownCoordinator.cleanup(reason: String(describing: restartReason(for: failure)))
            return
        }
```

- Health check loop's two failure sites (`vm not running` ~line 576 and post-grace exit-code failure ~line 608): `await state.markFailed(.healthCheck(message))`.
- `provisionerOutcomeLabel` (~line 977): `case .monitorFailed: return "monitorFailed"`.

- [ ] **Step 4: Run tests and build to verify**

Run: `swift test 2>&1 | tee $TMPDIR/t7.log`
Expected: full suite PASS (this task is a behavior-preserving refactor plus one new enum case; any remaining `healthCheckFailed(String)`/`markFailed(message:)` reference is a compile error — the compiler is the checklist).

- [ ] **Step 5: Commit**

```bash
git add Sources/sand/RestartBackoff.swift Sources/sand/Runner.swift Tests/sandTests/RestartBackoffTests.swift
git commit -m "Generalize health check failure channel to MonitorFailure with runnerOffline reason"
```

---

### Task 8: Offline monitor task and wiring

**Files:**
- Modify: `Sources/sand/Runner.swift` (github provisioner branch of `runOnce`, new `startOfflineMonitor`, extend the local `stopHealthCheck` helper)
- Modify: `Sources/sand/RunnerControl.swift`
- Modify: `Sources/sand/Sand.swift` (signal handler)

**Interfaces:**
- Consumes: `OfflineTimer` (Task 3), `GitHubService.runnerStatus(named:)` (Tasks 4-5), `recycleAfterOffline` (Task 6), `MonitorFailure`/`markFailed(.runnerOffline(...))` (Task 7).
- Produces:
  - `RunnerControl.setOfflineMonitorTask(_:)`, `takeOfflineMonitorTask() -> Task<Void, Never>?`, `cancelOfflineMonitor()`.
  - `Runner.startOfflineMonitor(github:runnerName:threshold:control:state:) -> Task<Void, Never>` (private).
  - Monitor starts after the setup commands (through `config.sh`) succeed and before `run.sh` runs; it is cancelled *and awaited* on every exit path of `runOnce` past that point.

No new unit test: the monitor loop's decision logic lives entirely in `OfflineTimer` (Task 3) and `runnerStatus` (Tasks 4-5), both unit-tested; the loop itself drives real time and the GitHub API. Verification is build + full suite + the manual acceptance check in Task 9.

- [ ] **Step 1: Extend RunnerControl**

In `Sources/sand/RunnerControl.swift`, add alongside the health check task storage:

```swift
    private var offlineMonitorTask: Task<Void, Never>?

    func setOfflineMonitorTask(_ task: Task<Void, Never>) {
        offlineMonitorTask = task
    }

    func takeOfflineMonitorTask() -> Task<Void, Never>? {
        let task = offlineMonitorTask
        offlineMonitorTask = nil
        return task
    }

    func cancelOfflineMonitor() {
        let task = offlineMonitorTask
        offlineMonitorTask = nil
        task?.cancel()
    }
```

- [ ] **Step 2: Add the monitor to Runner**

In `Sources/sand/Runner.swift`, add next to `startHealthCheck`:

```swift
    private static let offlinePollInterval: TimeInterval = 60

    private func startOfflineMonitor(
        github: GitHubService,
        runnerName: String,
        threshold: TimeInterval,
        control: RunnerControl,
        state: HealthCheckState
    ) -> Task<Void, Never> {
        Task {
            let clock = ContinuousClock()
            var timer = OfflineTimer(threshold: .seconds(threshold))
            logger.info("offline monitor active (runner=\(runnerName), recycleAfterOffline=\(Int(threshold))s, poll=\(Int(Self.offlinePollInterval))s)")
            while !Task.isCancelled {
                let signal: OfflineTimer.Signal
                do {
                    if let status = try await github.runnerStatus(named: runnerName) {
                        signal = (status.busy || status.online) ? .healthy : .offline
                    } else {
                        signal = .offline
                    }
                } catch {
                    signal = .unknown
                    logger.warning("offline monitor: runner \(runnerName) status unknown, timer frozen: \(String(describing: error))")
                }
                if Task.isCancelled {
                    break
                }
                if timer.observe(signal, at: clock.now) {
                    let message = "runner \(runnerName) offline on GitHub for \(Int(threshold))s of confirmed observations"
                    logger.warning("\(message); recycling VM")
                    // Record the outcome first so the restart is attributed to the
                    // offline runner, not to a generic provisioner exit.
                    await state.markFailed(.runnerOffline(message))
                    await control.terminateProvisioning()
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: nanos(from: Self.offlinePollInterval))
                } catch {
                    self.logger.debug("offline monitor sleep cancelled")
                    return
                }
            }
            self.logger.debug("offline monitor cancelled (runner=\(runnerName))")
        }
    }
```

- [ ] **Step 3: Wire start/stop into runOnce**

In `runOnce`, extend the local stop helper (currently `func stopHealthCheck(_ task: Task<Void, Never>) async` at ~line 186) to also stop the monitor, and rename it so every existing call site is forced through the compiler:

```swift
        func stopMonitors(_ task: Task<Void, Never>) async {
            logger.debug("healthCheck task cancel requested")
            task.cancel()
            await control.clearHealthCheckTask()
            if let monitor = await control.takeOfflineMonitorTask() {
                monitor.cancel()
                // Await the task out: a poll mid-flight must not act on a
                // successor boot (spec: cancellation alone is not sufficient).
                await monitor.value
            }
        }
```

Rename all `stopHealthCheck(healthCheckTask)` calls to `stopMonitors(healthCheckTask)` (compiler-enforced; ~13 sites).

In the `.github` branch, split the provisioner commands so the monitor starts after registration (`config.sh`) and before `run.sh`. Replace:

```swift
                let commands = provisioner.script(config: githubConfig, runnerToken: token, runnerName: uniqueRunnerName)
                let outcome = await runProvisionerCommands(commands, ssh: ssh, healthCheckState: healthCheckState)
```

with:

```swift
                let commands = provisioner.script(config: githubConfig, runnerToken: token, runnerName: uniqueRunnerName)
                let setupCommands = Array(commands.dropLast())
                let runCommand = commands.last ?? ""
                let setupOutcome = await runProvisionerCommands(setupCommands, ssh: ssh, healthCheckState: healthCheckState)
                switch setupOutcome {
                case .completed:
                    break
                case let .failed(error):
                    if await handleStageFailure(error, stage: "provisioner", healthCheckState: healthCheckState) {
                        await stopMonitors(healthCheckTask)
                        await shutdownCoordinator.cleanup(reason: "provisioner failed")
                        return
                    }
                    await stopMonitors(healthCheckTask)
                    await shutdownCoordinator.cleanup(reason: "provisioner failed")
                    throw error
                case let .monitorFailed(failure):
                    await scheduleRestart(reason: restartReason(for: failure))
                    await stopMonitors(healthCheckTask)
                    await shutdownCoordinator.cleanup(reason: String(describing: restartReason(for: failure)))
                    return
                }
                if githubConfig.recycleAfterOffline > 0 {
                    let monitorTask = startOfflineMonitor(
                        github: github,
                        runnerName: uniqueRunnerName,
                        threshold: githubConfig.recycleAfterOffline,
                        control: control,
                        state: healthCheckState
                    )
                    await control.setOfflineMonitorTask(monitorTask)
                } else {
                    logger.info("offline monitor disabled (recycleAfterOffline: 0)")
                }
                let outcome = await runProvisionerCommands([runCommand], ssh: ssh, healthCheckState: healthCheckState)
```

The existing `switch outcome` below stays as refactored in Task 7. (`GitHubProvisioner.script` returns a fixed array whose last element is the `run.sh` invocation; `dropLast` leaves everything through `config.sh` plus a trailing `echo`.)

- [ ] **Step 4: Signal shutdown**

In `Sources/sand/Sand.swift`, inside the `SignalHandler` closure, after `await control.cancelHealthCheck()` add:

```swift
                    await control.cancelOfflineMonitor()
```

- [ ] **Step 5: Build and run the full suite**

Run: `swift test 2>&1 | tee $TMPDIR/t8.log`
Expected: full suite PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/sand/Runner.swift Sources/sand/RunnerControl.swift Sources/sand/Sand.swift
git commit -m "Recycle VM when GitHub reports the runner offline past recycleAfterOffline"
```

---

### Task 9: End-to-end verification

**Files:** none (verification only).

- [ ] **Step 1: Full suite from clean state**

Run: `swift build -c release 2>&1 | tee $TMPDIR/t9-build.log && swift test 2>&1 | tee $TMPDIR/t9-test.log`
Expected: release build succeeds; all tests pass.

- [ ] **Step 2: Fixture validates**

Run: `swift run sand validate --config fixtures/sample_full_config.yml 2>&1 | tee $TMPDIR/t9-validate.log`
Expected: validation succeeds (exit 0). If the `validate` subcommand requires the private key path to exist, expect exactly and only that pre-existing error (it references `~/my-app.private-key.pem`) — no new errors mentioning `recycleAfterOffline`.

- [ ] **Step 3: Spec acceptance sweep**

Re-read `docs/plans/runner-self-healing-spec.md` "Fix" requirements and confirm each maps to landed code:

- busy never recycles / busy-or-online resets → `OfflineTimer` `.healthy` mapping in `startOfflineMonitor` + `OfflineTimerTests.healthyResetsAccumulation`.
- unknown freezes, accumulated-time semantics → `OfflineTimerTests.unknownIntervalAddsZeroAccumulatedTime` / `unknownDoesNotResetAccumulation`.
- monitor starts post-`config.sh` → command split in `runOnce`.
- outcome recorded before termination → `startOfflineMonitor` calls `markFailed` before `terminateProvisioning`.
- stale monitor cannot act on successor → `stopMonitors` awaits `monitor.value`; signal path cancels via `RunnerControl.cancelOfflineMonitor`.
- token reuse with expiry/401 → `GitHubServiceTests` cache tests.
- `recycleAfterOffline` default/0/negative → Config + validator tests.
- distinguishable restart reason → `RestartReason.runnerOffline` + `RestartBackoffTests`.
- SSH `ConnectTimeout`/`ServerAlive` → `SSHClientTests`.
- IP-resolve pacing + warning → Task 2 diff.

Report any requirement without a checkmark as a gap before declaring done.
