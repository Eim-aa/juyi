# Native owner handoff protocol

Status: protocol and durable-store foundation implemented; native activation is still **NO-GO**.

This slice closes the legacy half of the single-owner problem without enabling
the native double-Option monitor. When no owner request exists, Hammerspoon
continues to be the only production trigger exactly as before. The store is
compiled only for the isolated Debug `JUYI_NATIVE_OWNER_HANDOFF_LAB` slice and
has no App action, live status reader, timer, or monitor, so default Debug and
every supported Release build still create no request.

## Durable request

The future native owner will atomically publish an owner-only file at:

```text
~/.config/argos-translator/owner-request.json
```

The only accepted version-1 payload has exactly four keys:

```json
{
  "epoch": "11111111-2222-3333-4444-555555555555",
  "native_instance_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
  "requested_owner": "native",
  "version": 1
}
```

Both identifiers must be canonical UUIDs. Unknown keys, malformed JSON,
oversized content, a missing identifier, an unknown version, or an unreadable
file are fail-closed: the legacy watcher remains stopped and no yielded
acknowledgement is minted. Confirmed `ENOENT` is the only state that permits the
legacy owner to resume.

The isolated store uses owner-only directory/file validation, `O_NOFOLLOW`,
0600 files, an exclusive non-overwriting atomic rename, file and directory
`fsync`, exact readback, and a stable cross-process native-owner lock named
`native-owner.lock`. The returned lease
holds an exclusive nonblocking `flock` for the entire candidate native-owner
lifetime, so two Juyi processes cannot both proceed. The lock file is never
unlinked.

An existing canonical request is never overwritten. After a crash, a new begin
returns recovery-required; the only recovery API returns a `recoveryOnly` lease
which can remove the exact request and return to legacy, but cannot authorize a
native monitor. Releasing or destroying a lease preserves the request and thus
leaves zero owners. Temporary files use unique names and do not block recovery.

## Legacy quiesce barrier

Hammerspoon checks the durable request before starting its event tap and once
per second thereafter. A valid native request first:

1. advances the request generation;
2. stops every pending request timer;
3. removes the active request capability;
4. stops the double-Option watcher;
5. resets partial gesture state; and
6. dismisses the popup and its event watcher.

Only after those effects are gone does it publish `owner_state = "yielded"`.
Pause now uses the same full barrier; it no longer means only “watcher off”.
Queued HTTP completions retain stale generations and cannot recreate a popup.

`hs-status.json` now includes:

- `owner_protocol_version`
- `legacy_instance_id`
- `owner_state`
- `owner_request_epoch`
- `owner_request_native_instance_id`
- `watcher_active`
- `active_request`
- `popup_visible`
- `status_sequence`
- `updated_at`

The instance ID is generated once per loaded Lua module. If the installed
Hammerspoon cannot provide a canonical UUID, it reports a non-UUID fallback;
the native policy deliberately refuses to activate from that status.

## Native acceptance policy

`macos/NativeOwnerHandoffProtocol.swift` is pure and performs no file, process,
monitor, AX, translation, popup, or clipboard work. It accepts a handoff only
when one fresh status snapshot proves all of the following:

- protocol version 1 and module still loaded;
- `owner_state == "yielded"`;
- exact request epoch and native instance match;
- canonical legacy instance ID;
- watcher, active request, and popup are all false;
- positive status sequence; and
- timestamp age is at most 2.5 seconds, with at most 1 second future skew.

Missing fields are unsafe rather than backward-compatible. A safe decision
returns an opaque value binding the native instance, request epoch, legacy
instance, and observed status sequence. It still does **not** authorize a
monitor by itself; activation additionally needs the durable writer, process
lock, lifecycle revocation, and real-device evidence below.

The isolated `NativeOwnerHandoffWorkflow` now owns the deterministic request
lifecycle. It publishes through the store, retains the process lease, accepts
only injected snapshots that pass the policy, and can time out, cancel, or use
a recovery-only lease to return to legacy. Transitional unsafe snapshots remain
waiting for a caller-owned monotonic five-second deadline. The workflow has no
status file reader or scheduler and exposes no native-activation operation;
even its `legacyYielded` phase therefore means only “safe snapshot observed”,
not permission to install a monitor. Any future activation must take another
fresh snapshot immediately before its first effect.

## Crash and restart behavior

- Hammerspoon restart while a valid request remains: reconcile before starting
  the event tap, so there is no transient legacy-owner window.
- Native crash after publishing a request: zero owners is allowed; the durable
  request keeps Hammerspoon yielded.
- Invalid or unavailable request: zero owners, `owner_state = "blocked"`.
- Explicit native return to legacy: stop native capture/popup first, release its
  capabilities, then remove the request. Hammerspoon resumes only after it
  observes confirmed absence.

## Remaining activation P0

- A live status reader, monotonic scheduler, and disclosed UI around the pure
  workflow, including lifecycle-driven return and recovery.
- Immediate native monitor/capture/domain/overlay revocation before returning
  ownership or pausing.
- Hammerspoon/Juyi crash, reload, multi-process, stale-status and every cutpoint
  test with proof that the system has zero or one trigger owner, never two.
- Signed macOS 15.0/latest 15.x, arm64/Intel, clean TCC, sleep/session/revoke,
  VoiceOver/FKA, focus, popup, clipboard, and privacy observation matrices.

Until those gates pass, Hammerspoon remains the sole production double-Option
owner. This protocol does not connect the Capture Lab, Apple Translation,
Volcengine, the native overlay, or any production selection text.
