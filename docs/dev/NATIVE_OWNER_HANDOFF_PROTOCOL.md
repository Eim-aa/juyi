# Native owner handoff protocol

Status: the existing version-1 owner protocol is now used by the production Apple offline translation MVP.

Hammerspoon and the native App never intentionally monitor double Option at the same time. Native activation is allowed only after Hammerspoon has acknowledged the exact request and reported that its watcher, active request and popup are all gone. The native process keeps the cross-process lock and durable request for its complete active lifetime.

## Durable request and acknowledgement

The native candidate writes an owner-only request at:

```text
~/.config/argos-translator/owner-request.json
```

The accepted version-1 payload contains exactly `version`, `requested_owner`, `epoch` and `native_instance_id`. Both identifiers are canonical UUIDs. The store uses an owner-only directory, 0600 files, `O_NOFOLLOW`, a non-overwriting atomic rename, file/directory `fsync`, exact readback and the stable `native-owner.lock`. A second Juyi process cannot claim the same owner.

Hammerspoon reconciles the request before starting its watcher and once per second afterwards. For a valid request it invalidates pending callbacks, stops request timers and the watcher, clears the active request, resets the gesture and dismisses the popup before publishing `owner_state = "yielded"`.

`hs-status.json` binds that acknowledgement to the exact epoch, native instance and current Hammerspoon instance. The native policy additionally requires protocol version 1, a positive sequence, a fresh timestamp, `module_loaded == true`, and false watcher/request/popup fields. Missing, malformed, stale, mismatched, symlinked, oversized or writable-by-others state fails closed.

## Production activation and return

`NativeProductionTranslationCoordinator` owns the production sequence:

1. verify Accessibility and Apple language readiness;
2. publish the durable request while holding the lock;
3. poll the bounded status reader for at most five seconds;
4. start `NativeOptionMonitor` only after the exact yield is accepted;
5. retain the lease while native capture, translation and overlay can run;
6. stop every native effect before removing the request and allowing Hammerspoon to resume.

Pause, user stop, engine switch, sleep, session resignation, authorization revocation and termination all use the same ordering. A cancelled asynchronous readiness result is generation-gated and cannot publish a later request. If the exact request cannot be removed, the UI reports that owner return is unconfirmed and the held lease can retry removal; it never claims that Hammerspoon resumed early.

## Crash and restart behavior

- A native crash leaves the request but releases the process lock. Hammerspoon stays yielded, producing zero owners rather than two.
- On the next activation or disabled-state reconciliation, Juyi acquires a recovery-only lease, removes only the canonical stale request, then either remains disabled or starts a fresh handoff.
- A live second Juyi process still holding the lock makes recovery busy and cannot be overridden.
- Invalid or unavailable request/status state keeps native activation closed.

The existing Debug owner lab remains compile-time gated and is not part of production activation. Production owner/store/workflow/status/activation types are present in ordinary Debug and Release builds because the real user chain depends on them.

## Release validation still required

Before distribution, validate the owner sequence on signed macOS 15 builds across Hammerspoon reload/crash, Juyi crash/relaunch, duplicate processes, stale status, pause/sleep/session transitions and Accessibility revocation. The acceptance criterion is observable zero-or-one trigger owner at every cut point, followed by successful real selection → Apple Translation → native popup behavior.
