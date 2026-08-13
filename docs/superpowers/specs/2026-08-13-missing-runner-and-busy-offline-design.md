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
- `unrecognized` → `.unknown` regardless of busy (behavior change: today
  `unrecognized && busy` maps to `.healthy` and resets the timer; under
  connection-first mapping an unrecognized status no longer vouches for health,
  so prior offline accumulation is preserved instead of reset)
- `.notRegistered` → `.offline` (unchanged, backstop accrual behind the fast path)

A `busy` field absent from the API response already decodes as `false`
(`GitHubService.fetchRunnerStatus`), so `offline` with absent `busy` accrues
offline time rather than freezing. That stays as is: GitHub's schema marks
`busy` required, so absence is anomalous, and accruing is the recovery-friendly
default.

`OfflineTimer` is untouched: `.unknown` already clears `lastOffline` without
resetting `accumulated`.

Accepted tradeoff of freezing (2B over 2A): for the crash-mid-job sequence
`online+busy → offline+busy` the timer holds at zero, so recycling still waits
for GitHub to reap the job (`busy` → false, commonly ~10 minutes) plus the full
threshold. The freeze only fixes the flap case where accumulated offline time
was being erased. This is the deliberate risk posture: never recycle a runner
GitHub still considers busy, even at the cost of slower recovery from mid-job
crashes.

Log a warning once on entering the `offline+busy` state (mirroring the existing
`offlineRun` transition logs) so operators can see why the timer is frozen, and
clear that latch when the runner leaves the state.

### Missing fast path (1B)

`OfflineMonitor.run()` tracks a missing streak alongside the timer. The streak
counts consecutive *successful* observations, not consecutive polls:

- Successful poll returning `.notRegistered` increments the streak.
- Successful poll finding the runner (any status) resets it to 0.
- Failed poll leaves the streak unchanged. This is deliberate: an error neither
  confirms nor denies, and misses separated by an error gap are independent
  samples of absence — spreading them out makes a stale-list false positive
  less likely, not more. Three misses interleaved with arbitrarily many poll
  errors still trigger the fast path.
- When the streak reaches `missingPollThreshold = 3` (hardcoded `static let`),
  recycle immediately with cause "missing" instead of waiting for the timer.

At the default 60s poll interval detection takes ~2 minutes. Three
confirmations guard against a transiently stale empty list from the API.

The fast-path check runs before the timer verdict in the poll loop, so when
both would trip on the same poll the recycle is attributed to `missing`. This
only guarantees attribution on ties: `recycleAfterOffline` accepts any positive
value (values below 120s merely warn), and a threshold ≤ one poll interval trips
the timer on the second missing poll — before the third miss — so such configs
recycle with the `offline` cause. Acceptable: the VM is recycled either way and
sub-floor thresholds are already warned against.

When `recycleAfterOffline: 0`, no monitor is constructed at all
(`Runner.makeOfflineMonitor` is skipped), so disabling offline recycling also
disables missing-runner detection. That is the intended meaning of "disabled":
`0` turns off GitHub-status-based recycling entirely, and the `run.sh` exit
path remains the only recycler.

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

The distinct `backoffKey` prevents missing-caused restarts from escalating the
`runnerOffline` attempt counter (and vice versa) and makes logs name the actual
cause. Note `RestartBackoff` keeps only one `lastReason`, so alternating causes
reset the attempt count to 1 each time — that is existing behavior for all
reason kinds, not a new escalation track per key. Messages: missing →
"runner <name> no longer registered on GitHub"; offline → existing "offline on
GitHub past threshold" message.

### Out of scope

- Polling by runner ID (1E), webhooks, idle-age recycling, new config keys.
- README/config schema changes beyond one sentence in the existing
  `recycleAfterOffline` paragraph noting that a deregistered runner is recycled
  after ~3 poll cycles without waiting for the threshold.

## Testing

Existing tests that encode busy-first mapping (`signalMapping()`,
`busyRunnerNeverRecyclesAndErrorsFreeze()` in `OfflineMonitorTests`) are
updated to the connection-first expectations.

- `signal(for:)` cases: `offline+busy` → `.unknown`; `offline+idle` → `.offline`;
  `unrecognized+busy` → `.unknown`; `online` (busy and idle) → `.healthy`;
  `.notRegistered` → `.offline`.
- Fast path in `OfflineMonitorTests` (existing poll-stub style with short real
  sleeps — the monitor owns its `ContinuousClock`, there is no injectable
  clock): three `.notRegistered` polls trigger recycle with `.missing`; two
  misses then a registered poll resets the streak; misses interleaved with
  multiple poll errors (miss, error, error, miss, error, miss) still trigger;
  offline-past-threshold still recycles with `.offlinePastThreshold`.
- Fast-path priority: threshold of two poll intervals with all-missing polls
  recycles with `.missing`, not `.offlinePastThreshold`; threshold of one poll
  interval with all-missing polls recycles with `.offlinePastThreshold` on the
  second poll (documents the sub-floor attribution).
- Timer-freeze regression: offline accrual, then `offline+busy` polls, then
  offline again — accumulated time is preserved (no reset).
- Warning latch: entering `offline+busy` logs one warning, repeated
  `offline+busy` polls do not repeat it, and leaving then re-entering the state
  logs again.
- `GitHubServiceTests`: `status: "offline", busy: true` decodes to
  offline+busy; `status: "offline"` with `busy` absent decodes to
  offline+`busy: false`.
- `RestartReason.runnerMissing`: description, backoffKey distinct from
  `runnerOffline` (RestartBackoffTests: missing-then-missing escalates,
  missing-then-offline resets).
- `RunnerRestartReasonTests`: `restartReason(for: .runnerMissing)` and
  `restartReason(forCompletedProvisionerWith: .runnerMissing)` both map to
  `RestartReason.runnerMissing`.
