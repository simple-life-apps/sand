# Missing-runner fast recycle and offline+busy freeze

Date: 2026-08-13
Branch: feat/runner-offline-recycling

## Problem

The offline monitor added on this branch treats two GitHub states suboptimally:

1. **Missing runner waits out the full offline threshold.** `OfflineMonitor.signal(for:)`
   maps `.notRegistered` to `.offline`, so a runner that GitHub has removed (admin
   removal, ephemeral retention cleanup) occupies a VM for the whole
   `recycleAfterOffline` window even though an ephemeral runner's registration is
   unrecoverable — its token is consumed and it can never take a job again.
   The restart reason also says "runner offline", which misattributes the cause.

2. **`offline + busy` resets the offline timer.** `signal(for:)` checks `busy` before
   the connection state, so `status: "offline", busy: true` maps to `.healthy`, which
   zeroes `OfflineTimer.accumulated`. A runner that dies mid-job stays `busy` until
   GitHub reaps the job for lost communication (~10 minutes, sometimes much longer),
   and a flapping runner can erase timer progress indefinitely. The SSH health check
   covers hard-dead VMs; the exposed case is a live VM whose runner process crashed
   or lost GitHub connectivity mid-job.

Verified against GitHub docs/OpenAPI: `status` is an open string with only
`"online"`/`"offline"` in examples ("Idle" in the UI is `online + busy: false`);
a missing runner returns `200` with an empty filtered list; GitHub auto-removes
ephemeral runners not connected for >1 day.

## Decision

Option 1B (consecutive-miss fast path) and option 2B (freeze on `offline+busy`),
no new config keys.

## Design

### Signal mapping (2B)

`OfflineMonitor.signal(for:)` becomes connection-first for registered runners:

- `online` → `.healthy` (busy irrelevant; idle runners stay healthy)
- `offline && busy` → `.unknown` (timer freezes: no accrual, no reset)
- `offline && !busy` → `.offline`
- `unrecognized` → `.unknown` (unchanged)
- `.notRegistered` → `.offline` (unchanged, backstop accrual behind the fast path)

`OfflineTimer` is untouched: `.unknown` already clears `lastOffline` without
resetting `accumulated`.

Log a warning once on entering the `offline+busy` state (mirroring the existing
`offlineRun` transition logs) so operators can see why the timer is frozen, and
clear that latch when the runner leaves the state.

### Missing fast path (1B)

`OfflineMonitor.run()` tracks a consecutive-missing streak alongside the timer:

- Successful poll returning `.notRegistered` increments the streak.
- Successful poll finding the runner (any status) resets it to 0.
- Failed poll leaves the streak unchanged (an error neither confirms nor denies).
- When the streak reaches `missingPollThreshold = 3` (hardcoded `static let`),
  recycle immediately with cause "missing" instead of waiting for the timer.

At the default 60s poll interval detection takes ~2 minutes. Three consecutive
confirmations guard against a transiently stale empty list from the API.

The fast-path check runs before the timer verdict in the poll loop, so when a
minimal threshold (two poll intervals) and the miss streak would both trip on
the same poll, the recycle is attributed to `missing`.

### Distinct restart reason

`onRecycle` currently passes only a message, and `Runner` hardcodes
`MonitorFailure.runnerOffline`. Change the callback to carry a cause:

- `OfflineMonitor.RecycleCause: Equatable, Sendable` with cases
  `offlinePastThreshold` and `missing`; `onRecycle` becomes
  `@Sendable (RecycleCause, String) async -> Void`.
- New `MonitorFailure.runnerMissing(String)` and
  `RestartReason.runnerMissing(String)` (description
  `"runner missing: <message>"`, backoffKey `"runnerMissing"`), mapped through
  `Runner.restartReason(for:)` and `makeOfflineMonitor`'s closure.

This gives `RestartBackoff` a separate escalation track and makes logs name the
actual cause. Messages: missing → "runner <name> no longer registered on GitHub";
offline → existing "offline on GitHub past threshold" message.

### Out of scope

- Polling by runner ID (1E), webhooks, idle-age recycling, new config keys.
- README/config schema changes beyond one sentence in the existing
  `recycleAfterOffline` paragraph noting that a deregistered runner is recycled
  after ~3 poll cycles without waiting for the threshold.

## Testing

- `signal(for:)` cases: `offline+busy` → `.unknown`; `offline+idle` → `.offline`;
  `online` (busy and idle) → `.healthy`; `.notRegistered` → `.offline`.
- Fast path in `OfflineMonitorTests` (existing manual-clock/poll-stub style):
  three consecutive `.notRegistered` polls trigger recycle with `.missing`;
  two misses then a registered poll resets the streak; a poll error between
  misses preserves the streak; offline-past-threshold still recycles with
  `.offlinePastThreshold`.
- Timer-freeze regression: offline accrual, then `offline+busy` polls, then
  offline again — accumulated time is preserved (no reset).
- `RestartReason.runnerMissing`: description, backoffKey distinct from
  `runnerOffline` (RestartBackoffTests escalation isolation).
- `Runner.restartReason(for: .runnerMissing)` mapping in
  RunnerRestartReasonTests.
