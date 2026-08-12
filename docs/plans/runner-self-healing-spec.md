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
name, and recycles the VM through the existing restart path when the runner has been
continuously offline (or absent) for longer than a threshold.

Requirements:

- Never recycle a runner that GitHub reports `busy`.
- GitHub API errors mean status *unknown*: the offline timer must not advance, and must
  not reset; log a warning.
- Any observation of the runner online resets the timer.
- Polling starts once the runner is registered (provisioning done); a runner that never
  comes online is recycled when the threshold expires.
- One config key on the github provisioner: `offlineAfter` (seconds, default 600,
  `0` disables). Poll interval is fixed (60s).
- The restart reason is distinguishable in logs from health check failures.

## Code errors to fix alongside (all provisioners)

- `SSHClient` sets no `ConnectTimeout`; a black-holing host stalls a health check tick
  indefinitely. Add `ConnectTimeout=10`.
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

- Unit-tested offline-timer behavior: unknown freezes, busy never fires, online resets,
  continuous offline ≥ threshold fires, `offlineAfter: 0` disables.
- Config decoding/validation and `fixtures/sample_full_config.yml` cover `offlineAfter`.
- Replaying the incident (runner registered, then permanently offline, VM/SSH healthy)
  recycles the VM within ~`offlineAfter` + one poll interval.
