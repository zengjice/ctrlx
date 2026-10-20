# Pane reuse and Viewer viewing

`open` returns this pane's existing default device without restarting its app or
changing its profile. Simultaneous default opens share one startup. Reuse still
works at the configured device limit. An explicit runtime/type/profile/UDID that
differs from that default, or required features it lacks, fails: use `open --new`
for an additional device, or explicitly close the old one first. `--new` devices
stay independent and do not replace the pane's default. Another live agent in the
same pane does not inherit ownership; all writes retain the process identity check.
Closing the default removes its association; a later `open` obtains a new live ID.

Devices belong to the Host service. Closing its workbench only detaches local
presentation; reopening the workbench adopts the same device. The agent may open
from its Host terminal while that workbench is closed. `show` selects a local view
when available; it does not force a Viewer selection or open a Host window.
Explicit Host/CLI device close, owner exit, or Host App exit still shuts it down.
Visible local tabs and successful remote viewing prevent hidden-idle cleanup.

Mac Viewer shows simulator tabs marked Host; iOS lists them under **Tabs → iOS
Simulators on Host**. Select one to watch; selection stays private to that client.
Updated Hosts offer explicit **Take Control**, touch selection and **Copy / Paste**
between the selected simulator and the Viewer's local clipboard. The Copy menu's
**Get Simulator Clipboard** retrieves content already copied inside the guest.
This never synchronizes the Host's global clipboard. Host human input takes control
back immediately; agents cannot claim during a Viewer lease. Older Hosts remain
read-only. These surfaces have no device close or rotation action.
Switching away, backgrounding or disconnecting releases control and stops polling. Reconnection requests
fresh frames. Old Hosts without the capability cannot receive simulator requests.

Preview uses the existing encrypted Relay connection with one pending frame per
surface and a 180 ms pause after each reply. This is roughly up to 5.6 updates/s
before network/encoding time, not the local frame-rate guarantee. JPEGs fit the
Viewer canvas, never upscale, and are capped at a 2560-pixel long side / 512 KiB.
Agent PNG screenshots drain an in-flight preview and take priority over the next
preview. Same-size concurrent requests share encoding; congestion pauses captures before
terminal work. Preview is in memory and does not start a recording or write files.
Real cross-device acceptance is reported separately in the design document.
