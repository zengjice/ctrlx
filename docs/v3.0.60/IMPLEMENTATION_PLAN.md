# Agent iOS pane reuse and Viewer viewing

Scope approved on 2026-10-13 for the `agent-ios` worktree. This is a local
implementation record; release/version metadata is unchanged.

1. Make `ctrlx ios open` reuse the source pane's default, coalescing startup.
   `open --new` preserves intentional multi-device use. Retain live process
   ownership, resource admission and shutdown ordering.
2. Let the Host service own devices independently of a workbench window.
   Detached devices can be observed by Viewers and adopted by a reopened local
   workspace. Keep pane routes current and preserve explicit device closure.
3. Add typed, capability-gated read-only simulator descriptors and previews to
   the existing E2EE channel. Use bounded native JPEG capture, shared same-size
   requests and the existing bounded preview queue outside terminal input.
4. Display the same Host devices in Mac and iOS Viewer tabs. Selection is local;
   hidden/background/disconnected surfaces stop polling. No remote device/input
   mutation or recording command is added.
5. Validate focused lifecycle/wire/native/UI behavior, build affected platforms,
   and update the current design plus agent operations/skill. Reuse unaffected
   historical input/recording evidence; record fresh acceptance separately.

Local performance thresholds remain >=50 FPS, <=100 ms display latency and
<=150 ms click response under the previously accepted local conditions. Remote
preview uses a 180 ms pause after each reply, <=2560-pixel long side and <=512 KiB
JPEG. Those are bounds, not a promise of local frame rates across a network.

Progress and actual validation: [stage checklist](STAGE1_TODO.md).
