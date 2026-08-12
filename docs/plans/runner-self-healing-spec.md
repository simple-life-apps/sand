# Spec: Recycle runners that go offline on GitHub

## Problem

A runner VM's guest→internet networking died ~4h after boot (host↔guest stayed fine).
The runner listener never reconnected to GitHub for 4 days; the runner was continuously
offline and took no jobs. sand never noticed: the health check (`pgrep run.sh`) kept
passing because `run.sh` relaunches the failing listener forever. Every host-side signal
(VM running, SSH reachable, process alive) looked healthy while the runner was useless.

## Fix

For the `github` provisioner, sand polls the GitHub API (from the host, whose network
is unaffected by guest egress failure) for the runner's status by its unique per-boot
name, and recycles the VM when the runner has been continuously offline (or absent)
for longer than a threshold.

Requirements:

- Never recycle a runner that GitHub reports `busy`.
- GitHub API errors mean status *unknown*: the offline timer must not advance, and must
  not reset; log a warning. "Not advance" means the threshold is accumulated
  confirmed-offline observation time (monotonic clock), not wall-time since the first
  offline observation — unknown intervals contribute zero.
- Any observation of the runner online or busy resets the timer.
- Polling starts once the runner is registered (`config.sh` succeeded) — not when the
  provisioner finishes, since its last command is the long-running `run.sh`. A runner
  that never comes online is recycled when the threshold expires.
- Recycling must interrupt the in-flight provisioner (`run.sh` wait) and schedule the
  restart, the same way a failed health check does; scheduling alone must not be
  assumed to interrupt anything. The offline outcome must be recorded before the
  process is terminated, so the restart is attributed to the offline runner rather
  than to a generic provisioner exit.
- A stale monitor (bound to a previous boot's runner name) must never be able to act
  on a successor boot. The poll task is cancelled on restart, cleanup, and signal
  shutdown, but cancellation alone is not sufficient — a poll mid-flight across an
  await can resume after cancellation, so its side effects must additionally be
  awaited-out or fenced (e.g. per-boot generation check) before the next boot starts.
- Polling must not re-authenticate every cycle: cache the installation token and
  refresh it before expiry (or once on 401, then retry), so steady-state cost is one
  GET per poll. Both failure modes — rate limiting from re-minting every poll, and an
  expired cached token turning every poll into "unknown" — would freeze the offline
  timer indefinitely.
- One config key on the github provisioner: `recycleAfterOffline` (seconds, default
  600, `0` disables). Poll interval is fixed (60s).
- The restart reason is distinguishable in logs from health check failures.

## Code errors to fix alongside (all provisioners)

- `SSHClient` sets no `ConnectTimeout`, so an unreachable host stalls a health check
  tick for the TCP-stack default (minutes). Add `ConnectTimeout=10`, plus
  `ServerAliveInterval`/`ServerAliveCountMax` to bound sessions that stall *after*
  connecting (ConnectTimeout alone only bounds connection establishment).
- The health check loop's IP-resolution failure path `continue`s past the interval
  sleep, so pacing relies only on `tart ip --wait`. It must sleep the interval.
- IP-resolution failures in the health check are logged at `.debug` and are invisible
  in persisted unified logs. Log at `.warning`.

## Non-goals

- No limit/deadline on SSH-level health check errors: observed SSH failures were
  intermittent and the existing retry handled them correctly. Unbounded retry there is
  acceptable while the VM is running and the GitHub signal exists.
- No change to health check command semantics or the `script` provisioner.
- Root-causing the guest egress failure (ops investigation, separate).

## Acceptance

- Unit-tested offline-timer behavior: unknown freezes (time advancing during an
  unknown interval adds zero accumulated offline time), busy never fires, online or
  busy resets, continuous offline ≥ threshold fires, `recycleAfterOffline: 0` disables.
- Config decoding/validation and `fixtures/sample_full_config.yml` cover
  `recycleAfterOffline`.
- Replaying the incident (runner registered, then permanently offline, VM/SSH healthy)
  recycles the VM within ~`recycleAfterOffline` + one poll interval.
