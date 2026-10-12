# Viewer browser access

Host Chromium pages are shared resources, not copies opened on the Viewer.
Manual, Agent and popup tabs keep their Host profile and session association.
WebKit and existing Viewer-local pages stay local. No public CDP port or Relay
protocol change is required.

1. Decouple native page lifetime from workbench presentation. Add bounded native
   frame capture/input and a page-level human control gate for both CLI engines.
2. Add capability-negotiated, encrypted browser commands and tab metadata. One
   controller per page, expiring leases, disconnect cleanup and stale-input rejection.
3. Integrate a shared remote browser surface into Mac Viewer tabs and iOS Tabs.
   Independent selection; explicit viewport fit; Chinese text uses committed IME
   input. Leaving a surface stops watching, not the Host page.
4. Test wire compatibility, authorization, cancellation, input coordinates and
   real hidden/native pages; compile both clients and update browser docs.

Frames use single-in-flight pull requests with capped JPEG bytes; there is no
frame backlog. Input is ordered and never retried after transport loss. Browser
requests must not hold the terminal command receive loop.

Not included: WebKit remote control, remote audio, file chooser/system dialogs,
external browsers, installation or release.
