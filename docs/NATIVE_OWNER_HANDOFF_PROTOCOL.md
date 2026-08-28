# Native owner handoff protocol

Status: protocol foundation implemented; native activation is still **NO-GO**.

This slice closes the legacy half of the single-owner problem without enabling
the native double-Option monitor. When no owner request exists, Hammerspoon
continues to be the only production trigger exactly as before. No current App
action creates `owner-request.json`.

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

The future writer is not implemented in this slice. Before activation it must
use owner-only directory/file validation, atomic rename plus directory `fsync`,
and a user-domain cross-process native-owner lock. It must hold that lock for the entire
native-owner lifetime, so two Juyi processes cannot both install a monitor.

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

- Native atomic request store and never-unlinked cross-process owner lock.
- A UI state machine for `legacyActive → stoppingLegacy → nativeActive` and the
  reverse path, with epoch-bound progress and recovery.
- Immediate native monitor/capture/domain/overlay revocation before returning
  ownership or pausing.
- Hammerspoon/Juyi crash, reload, multi-process, stale-status and every cutpoint
  test with proof that the system has zero or one trigger owner, never two.
- Signed macOS 15.0/latest 15.x, arm64/Intel, clean TCC, sleep/session/revoke,
  VoiceOver/FKA, focus, popup, clipboard, and privacy observation matrices.

Until those gates pass, Hammerspoon remains the sole production double-Option
owner. This protocol does not connect the Capture Lab, Apple Translation,
Volcengine, the native overlay, or any production selection text.
