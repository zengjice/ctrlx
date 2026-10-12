# On-demand simulator recording

Use recording to preserve animation, gestures or reproduction steps. It records
the guest display, without audio, desktop capture or macOS screen-recording permission.
Encoding adds work while active; ordinary display and input do not record by default.

```sh
ctrlx simulator record-start --device <id> --output /absolute/new.mp4 --seconds 30
ctrlx simulator pinch --device <id> --x 196 --y 400 --scale 2
ctrlx simulator record-status --device <id>
ctrlx simulator record-stop --device <id>
```

Start requires the device's owner and active writer. It waits for the recorder's
first frame (up to 10 seconds), then returns `state: recording`. Input can continue
while recording. Status and stop require the owner, but remain available after
human takeover without claiming control. Only one recording per device can run.
The three commands also work in `batch`; a failed batch does not roll back a start.

`--seconds` is an integer from 1 to 60, default 60. Reaching that duration stops
automatically. The recorder also requests stop when the temporary movie reaches
128 MiB; final files above that bound are rejected. Disk admission checks the
configured reserve on the output volume. This does not reserve disk against other apps.

Output must be an absolute new `.mp4` path in an existing writable directory.
Encoding uses H.264 through the private device set's `simctl recordVideo`.
It keeps the native display raster: rotation during a clip can appear sideways.
Frames arrive on display updates; a static screen can produce a very short movie.
The duration option bounds recording wall time, not guaranteed playback length.
The final path appears only after successful finalization; existing files are
never overwritten, including files created while recording is in progress.
Temporary files sit in a private sibling directory and are removed on completion
or failure. A forced host kill can leave the recorder and temporary directory behind.

Stop waits for finalization and is idempotent. `record-status` reports `idle`,
`starting`, `recording`, `stopping`, `completed` or `failed`, plus path, bytes,
duration limit and any stop reason/error. The last result remains until another
recording starts or the device closes. Check `state == completed` before using
the movie. A file or successful command alone does not prove you watched it.

Closing the device, owner expiry and normal host exit stop and reap recording
before shutting down the guest. Host exit starts all remaining recording stops
in parallel before waiting for device closes already in progress.
Finalization has a 15-second grace; an
unresponsive recorder is killed and its incomplete movie discarded. After a
start timeout, inspect status before deciding what remains; do not blindly replay.

This does not provide remote streaming, audio, editing, pause/resume or a general
screen recorder. New recording work has separate validation from earlier display
performance acceptance; that acceptance does not promise unchanged FPS while encoding.
