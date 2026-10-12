# App removal and private device storage

Use these operations when the task calls for uninstalling an app, resetting a test
environment or reclaiming device storage. Ordinary `close` and `open` preserve data.
All commands require the calling local agent's identity.

## Uninstall an app

```sh
ctrlx simulator uninstall --device <owned-ctrlx-id> --bundle com.example.app
```

Requires the same owner and active writer as other app changes. Human takeover
still requires an explicit handoff. Uninstall removes the specified app; it is
not a whole-device reset or a reset of remote account data. Observe before any retry.

## Inspect storage

```sh
ctrlx simulator storage
```

Lists guests in CtrlX's private device set, including closed guests retained for
reuse. This shared pool is broader than `devices`, which lists this agent's live
tabs. Each row includes `udid`, `name`, `runtime`, `deviceTypeIdentifier`, `state`,
`inUse`, `canModify` and `allocatedBytes`.

`inUse` covers host ownership, startup, cleanup and unresolved shutdown failures.
`canModify` additionally requires `Shutdown`; it is an observation, not a reservation.
Disk usage is an on-demand, bounded `du` measurement. Unknown bytes are `null`,
never zero; `diskUsageError` reports measurement failures. Allocated bytes are not
a promise of physical space freed, especially with shared filesystem blocks.

## Reset or delete one idle device

If the device is open in your session, first save its UDID and close its CtrlX tab:

```sh
ctrlx simulator status --device <owned-ctrlx-id>
ctrlx simulator close --device <owned-ctrlx-id>
ctrlx simulator storage
```

Choose exactly one operation on the intended UDID:

- `ctrlx simulator erase --udid <private-uuid>` removes the device's apps, data and
  settings, retaining the guest for reuse. It stays shut down.
- `ctrlx simulator delete --udid <private-uuid>` removes the guest and its data.

These operations require one UUID from the private set, a shut-down guest and no
active host reservation. They recheck state before changing it and serialize with
startup. They reject active devices; they do not force-close other agents' tabs or
accept `all`, arbitrary paths or system-default devices. No automatic sweeping occurs.

To reopen the exact guest after erasing it:

```sh
ctrlx simulator open --udid <private-uuid>
```

This returns a new CtrlX device ID. `--udid` cannot be combined with `--device`,
`--runtime` or `--device-type`; missing/busy/unavailable guests fail instead of
selecting another. Profiles default to `standard`; supply `--profile` / `--requires`
again if needed. Install the test app again after erase.

Erase/delete have bounded execution and may wait for startup or another storage
change. A timeout leaves the outcome unknown: inspect `storage` and the guest/app
state before deciding what remains. Failed writes are never automatically replayed.

Host exit cancels queued storage changes and stops/reaps running storage commands.
Cancellation can leave a partial or completed change; inspect the private guest
after restarting before deciding what remains. Browser and terminal cleanup do
not wait for storage commands to finish.
