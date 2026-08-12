# Spec: Runner self-healing (zombie-runner detection + health check hardening)

## Problem

Two production hosts (runner4, runner5) had runners stuck offline for days while sand
considered the VM healthy. Root cause analysis:

1. **Zombie runners are invisible to the health check.** The default health check
   (`pgrep -fl ~/actions-runner/run.sh`) verifies the runner *process* is alive. On both
   hosts the VM lost egress connectivity (socket timeouts from the runner to
   `*.actions.githubusercontent.com`), so the runner was offline on GitHub, but `run.sh`
   kept running and the health check kept passing. sand never recycled the VM.
2. **SSH-level health check errors retry forever.** In `startHealthCheck`
   (Runner.swift), a thrown SSH error (exit 255: auth denial, timeout, etc.) logs
   `will retry` and loops with no limit. IP-resolution failures similarly `continue`
   forever (and skip the interval sleep). Observed auth denials were intermittent, so
   this was not the primary stuck mechanism, but a persistently unreachable VM would
   wedge sand indefinitely today.
3. **Probe hangs are unbounded.** `SSHClient` sets no `ConnectTimeout`, so a
   black-holing host can stall a health check tick for many minutes.

## Goal

sand automatically recycles a VM whose runner can no longer take jobs, while making it
structurally impossible to recycle a VM that is actively executing a job.

## Non-goals

- Diagnosing/fixing the underlying VM egress degradation (separate ops investigation).
- Changing health check semantics for the `script` provisioner beyond the SSH
  deadline/backstop and hardening items.
- Multi-VM orchestration changes.

## Design

### 1. GitHub runner status polling (primary signal, `github` provisioner only)

- Extend `GitHubService.RunnersListResponse.Runner` with `status: String` and
  `busy: Bool` (already returned by the existing
  `GET .../actions/runners?name=<name>` endpoint used by `deleteRunner`).
- Add `GitHubService.runnerStatus(named:) async throws -> RunnerStatus?`
  (`nil` = not registered; otherwise `online/offline` + `busy`).
- New periodic poll owned by the runner lifecycle (a task parallel to the health check
  loop, started once provisioning has registered the runner under its unique per-boot
  name from `GitHubProvisioner.uniqueRunnerName`).
- Recycle rule: if GitHub reports the runner **offline (or not registered) continuously
  for `offlineAfter` seconds**, mark the runner failed via the existing
  `HealthCheckState.markFailed` → `scheduleRestart` path (new `RestartReason` case
  `runnerOffline(String)`).
- Safety invariants:
  - A runner reported `busy` is never recycled by this rule (busy implies online, but
    check explicitly).
  - GitHub API errors (network, 5xx, auth) count as *unknown*, never as offline: the
    offline timer does not advance; log at warning.
  - Timer starts only after the runner has been observed online at least once (or after
    a generous registration grace), so slow provisioning is not misread as offline.
- Defaults: poll every 60s, `offlineAfter` 600s. Configurable under
  `provisioner.config` (github): `offlinePollInterval`, `offlineAfter`; `offlineAfter: 0`
  disables the feature.

### 2. SSH unreachability deadline (backstop, all provisioners)

- In the health check loop, track `lastProbeSuccessAt` (initialized at activation).
  Successful probe execution (any exit code — SSH worked) refreshes it; SSH errors and
  IP-resolution failures do not.
- If `now - lastProbeSuccessAt > unreachableAfter`, mark failed with reason
  `healthCheckFailed("ssh unreachable for Ns")` — except, for the github provisioner,
  first consult the last-known GitHub status: if the runner is currently `busy`, extend
  the deadline (keep waiting) instead of recycling. Fail open on unknown status: do not
  recycle while status is unknown *and* the VM still reports `running`... — no: keep it
  simple and safe — recycle only when (a) deadline expired and (b) runner is not known
  busy. For the script provisioner there is no busy signal; the deadline alone applies.
- Default `unreachableAfter`: 900s. Configurable as `healthCheck.unreachableAfter`;
  `0` disables. Must be ≥ `healthCheck.interval` (validator warning otherwise).
- Startup grace unchanged.

### 3. Hardening (all provisioners)

- `SSHClient`: add `-o ConnectTimeout=10` to `exec`/`start`/`copy`.
- Fix the IP-resolution `continue` in the health check loop so it still sleeps the
  interval (no fast-spin; today pacing exists only via `tart ip --wait`).
- Raise IP-resolution failure logging in the health check from `.debug` to `.warning`
  so this path is visible in persisted logs (unchanged: success stays `.debug`).

## Config schema additions

```yaml
runners:
  - name: runner
    healthCheck:
      command: "pgrep -fl ~/actions-runner/run.sh"
      interval: 30
      delay: 60
      unreachableAfter: 900   # new, optional; 0 disables
    provisioner:
      type: github
      config:
        # ...existing fields...
        offlinePollInterval: 60   # new, optional
        offlineAfter: 600         # new, optional; 0 disables
```

Update `fixtures/sample_full_config.yml` and config tests.

## Testing

- `GitHubService.runnerStatus` decoding (online/offline/busy/absent) with stubbed
  `URLSessionProtocol`.
- Offline-timer state machine as a pure/actor unit: unknown never advances the timer,
  busy resets/never fires, continuous offline ≥ threshold fires, re-online resets.
- Deadline logic: probe success refreshes; SSH error + IP failure do not; expiry marks
  failed; busy defers.
- Config decoding/validation for new fields (including `0` = disabled and the
  `unreachableAfter < interval` validator warning).
- Existing tests keep passing.

## Open questions (resolve before plan)

1. Should `offlineAfter` recycling also fire when the runner was *never* observed
   online (registration grace expiry), or only after a seen-online→offline transition?
   Proposed: also fire after grace expiry — a runner that never comes online is equally
   stuck; grace default 15 min from registration.
2. Naming: `offlineAfter` / `unreachableAfter` vs `maxOffline` / `maxUnreachable`.
   Proposed: keep `*After` (reads as duration-until-action).
