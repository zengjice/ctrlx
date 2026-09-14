# SwiftTerm iOS Scrolling Architecture

This document details how SwiftTerm's `TerminalView` handles scrolling on iOS, the limitations discovered, and how Ctrlx works around them.

> **Dependency**: the Ctrlx fork is pinned in `CtrlxPackage/Package.swift`.
> Changing the sibling SwiftTerm worktree alone does not change that dependency.
> During local fork development, a temporary `../SwiftTerm` workspace reference
> overrides the remote package. Before committing/releasing Ctrlx, publish the
> fork revision, update the pin, and remove that local override.

## Overview

SwiftTerm's iOS `TerminalView` is a `UIScrollView` subclass that handles terminal rendering and scrollback navigation. Ctrlx wraps it in an additional scroll view to support wide terminals (horizontal scrolling), creating a nested scroll view architecture.

## Current viewport contract (September 2026)

- The inner terminal has the Host's exact row/column pixel dimensions. A passive
  canvas, not the terminal grid, expands to fill a larger phone viewport; the
  terminal is bottom-aligned inside it. The outer scroll view handles overflow.
- Terminal bytes and grid dimensions are applied in wire order. Auto Layout may
  update the native frame later. SwiftTerm must synchronize `contentSize` and
  `contentOffset` after that frame/inset change even if the grid already matches.
- `scroll(toPosition: 1)` targets the live screen's first row, not the current
  cursor row. A repeated request must synchronize pixels even when the logical
  display row is unchanged.
- Initial presentation waits for a native window and usable bounds. Input
  responder changes run separately, outside SwiftUI's synchronous update;
  the bottom anchor follows the resulting accessory/safe-area changes. Later
  reset/resize uses native viewport synchronization; neither path depends on
  another output byte.
- A layout update preserves deliberate history scrolling, fractional offsets,
  active dragging, history momentum and selection. It must not force the inner
  terminal to the bottom on every feed or layout.

See `terminal-rendering-investigation.md` for the reproduced 5-row drift and the
iOS-only regression suite. The sections below retain historical implementation
examples; old minimum-terminal-height constraints, scroll-blocking flags and
fixed-delay presentation snippets are **not** the current implementation.

## Deferred input focus (multi-pane hang)

Four iPhone Air watchdog reports on September 13, 2026 showed the same cycle:
`updateUIView → updateInput → become/resignFirstResponder → _UIHostingView
responderNode → AttributeGraph::print_cycle`. Switching between pane proxies
synchronously during SwiftUI's graph update prevented the main thread from
returning, including when the app tried to exit. This was a focus-reentrancy
bug, not a relay timeout or terminal-history replay stall.

`InteractiveTerminalView` now owns one `TerminalInputFocusUpdates` instance:

- `updateInput` immediately gates input but only records responder intent.
  A cancellable MainActor task suspends before applying the latest request.
- Mounting uses the same scheduler. Detached views cancel pending work;
  reattachment reapplies the latest state, even if its values are unchanged.
- `dismantleUIView` permanently invalidates the old view's pending requests.
  Failed focus acquisition is not marked applied and does not retry in a loop.
- Inactive terminals drop input from a still-focused proxy/accessory during
  the deferred handoff. No rendering, selection, IME-document, wire protocol,
  Mac, Relay, or SwiftTerm changes are needed for this fix.

Platform-independent scheduler tests cover deferral, coalescing, cancellation,
reattachment, teardown, failed acquisition, multi-pane handoff and the copy
page. Native selection/shortcut fixtures await the actual focus task. Device
acceptance must exercise entering 2+ panes, rapid pane/window changes, keyboard
show/hide, the copy page and exit/re-entry; check for new AttributeGraph cycles.

## Input toolbar layout

The first-row input controls and SwiftTerm's second-row shortcut accessory share
the 32-point `TerminalInputControlMetrics.buttonHeight`. Voice is microphone-only
in the first row, preserving hold-to-dictate and its accessibility label. Esc is
immediately before Send and sends one `.escape` through the normal toolbar queue;
it does not auto-repeat. The accessory hides Esc, horizontal arrows (already
present in the first row) and optional function keys,
then distributes its remaining controls across the available width. This is a
presentation configuration only: Ctrl/modifier handling, up/down auto-repeat,
touch mode, keyboard switching and the input proxy keep their existing paths.
SwiftTerm's `showsEscapeKey` defaults to `true`; only CtrlX opts out, so other
consumers retain their existing keyboard. Layout tests cover both configurations.

### Agent command panel

The first row's `/` button opens a native sheet for the selected **host + pane +
plugin**, not the session title. The adaptive button grid shows only command
names (such as `/model`), without descriptions or section headers. It adapts to
width and Dynamic Type, scrolls when needed, and can expand from medium to large.
Codex retains these 19 commands in order (no submenu or extra confirmation):

- Common: `/model`, `/status`, `/usage`.
- Session and context: `/plan`, `/compact`, `/resume`, `/fork`, `/rename`, `/agent`.
- Inspection and review: `/diff`, `/review`, `/ps`.
- Tools and settings: `/permissions`, `/skills`, `/mcp`, `/plugins`, `/theme`,
  `/statusline`, `/debug-config`.

Claude Code retains only `/model`, `/status` and `/usage`; unknown plugins have
no fallback commands. The flat catalog is also the submission allowlist, so
Codex-only commands cannot leak into another agent's panel or send path.
These are documented commands, not live discovery of every remote version's
capabilities (checked 2026-09-12; local Codex CLI 0.153.4;
[Codex reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli),
[Claude Code reference](https://code.claude.com/docs/en/commands)).
The remote CLI remains responsible for its own pickers and command support.
Commands that reset/delete sessions, exit/logout, stop background work or need
inline arguments are excluded, as are account/feature-gated toggles such as
`/fast`. `/compact` intentionally summarizes context.

Selecting a command submits immediately and closes the panel, without a
confirmation dialog or a second Send tap. Closing or swiping down sends nothing.
The `/` entry is enabled whenever the selected pane has a supported agent,
independently of whether it can currently receive input. While disconnected,
unready, awaiting a response/approval or in an external editor, the panel stays
browsable, explains the block, and disables only command submission. Working
agents are not blocked: the remote agent decides which commands it accepts
mid-turn. Availability updates in an open panel follow the live context and
recover automatically; the captured host/pane/plugin and local input revision
must still match. Atomic-reset state is observable so readiness refreshes even
when the stream stays `.streaming` throughout the reset.
Use it in the agent's empty normal composer. Neither terminal
pixels nor the native keyboard's shadow text is an authoritative draft model,
so the panel never clears text, injects Ctrl+C, or guesses emptiness from a
placeholder. Local keyboard/voice input and changes in target close the captured
panel and invalidate stale actions. The final send revalidates connection,
readiness, blocking forms and editor state before enqueueing any keys.

Selection immediately queues `[.text(command), .delay(200), .enter]` through the
existing FIFO toolbar key queue. The host separates literal text from Return by
200 ms, matching the reply composer's submission pattern so rapid-input/paste
detection does not turn Return into a newline. Keeping the delay in the existing
key protocol prevents network batching from removing this boundary. The command
cancels pending cursor correction like other toolbar keys.
It does not arm the background prompt monitor. The button retains the 32-point
control height. Keyboard is capped at 64 points (and may shrink further or use
its icon when space is tight), instead of taking all spare width. Send reserves
64 points, roughly twice the previous icon-only button, and always shows `Send`.
The first row uses 4-point gaps to keep the wider Send reachable on narrow phones.
No terminal renderer, SwiftTerm gesture, wire protocol or host change is needed.

Coverage: `AgentCommandMenuTests` checks catalog isolation, unique command IDs,
captured panel identity, browsing while blocked, live availability recovery,
working-agent submission, excluded commands, gating, immediate submission, exact key batches and
target/input invalidation for all 19 commands. `KeystrokeDebouncerTests` checks
immediate dispatch, FIFO ordering and preservation of the host-side delay and
Return. On a device, check dismissing the panel with a multiline draft, one-tap
command execution with an empty composer, switching split panes, dictation
finishing while the panel is open, and
the unchanged keyboard/selection/cursor controls on narrow screens.

## Cursor placement by single tap

- The original same-row shortcut is retained. Cross-row taps additionally need
  a recognizable live input surface: a prompt (`›`, `❯`, or `>`) with a shaded
  background, or an unshaded prompt enclosed by two horizontal borders. The
  cursor must be inside that same surface, and continuation rows must retain
  the input gutter. Background color or screen position alone is insufficient.
- Explicit newlines and visually wrapped rows use the editor's Up/Down keys.
  Ctrlx waits for the returned cursor before calculating Left/Right steps;
  it never guesses a remembered column or uses Home (which can jump to the
  start of a *logical* line instead of the tapped visual row). This matches
  [Codex's textarea navigation](https://github.com/openai/codex/blob/main/codex-rs/tui/src/bottom_pane/textarea.rs).
- Wide glyphs are one step, including their unstyled continuation cells.
  Prompt gutters and space beyond a short line clamp to the editable text;
  trailing blank padding is not clickable. Internal blank lines are supported.
  An ambiguous blank trailing draft line cannot be distinguished from padding
  unless it contains the live cursor. Unrecognized editors retain same-row
  placement only, rather than guessing a range that could navigate history.
- There is at most one outstanding batch of navigation keys, including same-row
  Left/Right. While waiting for its actual cursor feedback, keep only the latest
  valid tap in the same captured input region. Once that batch finishes, plan
  from the returned cursor directly to the latest target (skip obsolete column
  corrections). Never compute repeat-tap deltas from an unconfirmed cursor.
- A tap during hidden/synchronized redraw can be deferred when its nonblank row
  identifies a bounded input surface. No keys are sent until the real cursor is
  visible, synchronization ends, and it is inside that unchanged surface. Body,
  ambiguous blank padding and unrecognized shell rows do not opt into deferral.
- Each outstanding batch or initial redraw deferral expires after two seconds
  without retries; more taps do not extend an outstanding batch's deadline.
  Input-cell or viewport changes invalidate the request. Typing, IME composition
  (even if abandoned), parent-owned voice/shortcut input, selection, dragging,
  loss of focus, stream replacement and resize cancel both the batch's remaining
  correction and the queued destination. No buffer reset, forced scroll, polling,
  redraw timer, or terminal-stream change is involved.
- Single taps still wait for double/triple-tap recognition to fail. Removing this
  arbitration would move the remote cursor before a copy-menu tap is recognized;
  the copy/selection gesture contract is intentionally unchanged.

Coverage: `TerminalMultilineCursorNavigationTests` exercises region boundaries,
short/empty/wide-character lines, actual-column correction and stale feedback.
`TerminalCursorNavigationTests` covers latest-valid-tap coalescing, both-axis
feedback, redraw deferral, bounded timeout and cancellation of queued targets.
`TerminalCursorSnapshotTests` parses real SGR/DECTCEM bytes in SwiftTerm (with
and without scrollback). iOS `TerminalSelectionRoutingTests` additionally covers
feedback split across feeds, cancellation and unchanged selection/IME routing.

## Current input-row selection contract

- SwiftTerm's iOS `shouldBeginSelection(at:)` hook runs immediately before a
  double/triple tap creates a local selection. The default allows selection.
  A veto consumes the recognized tap; it does not fail the recognizer and fall
  through to single-tap cursor movement or URL opening.
- Ctrlx retains its original same-row heuristic for this hook, independently
  of the expanded single-tap navigation region:
  input must be enabled and focused, mouse reporting must be off, the inner
  terminal must be showing the live screen, and the hit must be on the current
  cursor row. A matching tap opens the standard menu at the hit without
  creating a selection, enabling handle dragging or sending keys. The hook
  controls automatic selection, **not** whether the menu can be opened.
- Without a terminal selection, the menu offers Paste / Select / Select All;
  Copy becomes available after an explicit selection. Select uses the tapped
  buffer position, including when the viewport has a nonzero scroll offset.
  An existing selection is preserved; no input text or placeholder is copied
  implicitly. Select All retains SwiftTerm's terminal-wide scope.
- The transparent `TerminalInputProxyView` remains the keyboard/IME first
  responder, but resolves Copy / Paste / Select / Select All to the visible
  terminal via `target(forAction:withSender:)`. Its shadow document is context
  for typing, not the source for terminal selection or clipboard commands.
- This is **not** semantic detection of a whole TUI editor. Adjacent rows of a
  multiline draft, history, inactive panes and mouse-mode TUIs retain selection.
  Do not broaden this copy-menu rule using the single-tap navigation region.
- Handle dragging, its magnifier/scroll exclusivity, single-tap selection exit,
  explicit copy actions and the separate copy page are unchanged. The hook does
  not modify terminal bytes, sizing or viewport synchronization.

Regression coverage: Ctrlx's `TerminalCursorTapNavigationTests` and iOS-only
`TerminalSelectionRoutingTests` exercise real double/triple tap handlers,
menu position, responder-chain action routing, native typing and marked-text
commits. The fork's iOS-only `IOSSelectionTapTests` covers menu-only taps,
explicit selection, scrolled
coordinates, existing selection preservation, single-tap exit and
mouse-reporting bypass. Unhosted package tests dispatch actions to the resolved
responder directly. `TerminalMenuHostTests`, run in a UIKit application host
with `CTRLX_MENU_UI_TESTS=1`, additionally checks actual menu presentation,
first-responder dispatch, clipboard contents and exact-once paste. It is
explicitly skipped in ordinary unhosted package runs, whose runner has no
foreground app responder chain for system menus and pasteboard reads.

## SwiftTerm Source Files

| File | Purpose |
|------|---------|
| `iOSTerminalView.swift` | iOS-specific TerminalView implementation |
| `AppleTerminalView.swift` | Shared rendering code (iOS + macOS) |

## Vertical Scrolling (Scrollback)

SwiftTerm fully supports vertical scrolling for terminal scrollback history.

### How It Works

1. **Content Size**: Set based on total buffer lines
   ```swift
   contentSize = CGSize(
       width: CGFloat(displayBuffer.cols) * cellDimension.width,
       height: CGFloat(displayBuffer.lines.count) * cellDimension.height
   )
   ```

2. **Scroll Position**: `contentOffset.y` determines which buffer lines are visible
   ```swift
   // In visibleRows calculation
   let topVisibleLine = contentOffset.y / cellDimension.height
   let bottomVisibleLine = topVisibleLine + frame.height / cellDimension.height - 1
   ```

3. **Rendering**: `drawTerminalContents()` uses `contentOffset.y` to determine which rows to render

### Scroll Methods

| Method | Description |
|--------|-------------|
| `scroll(toPosition: Double)` | Normalized position (0.0 = top, 1.0 = cursor position) |
| `scrollUp(lines: Int)` | Scroll up by N lines |
| `scrollDown(lines: Int)` | Scroll down by N lines |
| `scrollTo(row: Int)` | Jump to specific row |
| `pageUp()` / `pageDown()` | Scroll by one page |

### Important Note

`scroll(toPosition: 1)` scrolls to the **cursor position**, not necessarily the absolute bottom of content. The cursor is typically at the bottom, but this distinction matters.

## Horizontal Scrolling (NOT Supported)

**Critical Finding**: SwiftTerm does NOT support horizontal scrolling for wide terminals.

### Evidence

1. **contentOffset.x is hardcoded to 0** in `updateScroller()`:
   ```swift
   // iOSTerminalView.swift:992
   contentOffset = CGPoint(x: 0, y: CGFloat(displayBuffer.lines.count - displayBuffer.rows) * cellDimension.height)
   ```

2. **Rendering ignores contentOffset.x** - `lineOrigin.x` is always 0:
   ```swift
   // AppleTerminalView.swift:1209
   let lineOrigin = CGPoint(x: 0, y: frame.height - offset)
   ```

3. **No horizontal scroll gesture handling** - While `showsHorizontalScrollIndicator = true` is set, the terminal content won't pan horizontally.

### Impact

For wide terminals (more columns than fit on screen), the content is clipped on the right. There's no way to scroll horizontally to see clipped content using SwiftTerm alone.

## Ctrlx's Solution: Outer Scroll View + Content-Sized Terminal

Ctrlx wraps TerminalView in an outer UIScrollView. The terminal view is sized to match the terminal content exactly, and the outer scroll view handles both horizontal (wide terminals) and vertical (tall terminals) scrolling.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Outer UIScrollView (horizontal + vertical scrolling)        │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ InteractiveTerminalView (SwiftTerm subclass)            │ │
│ │ - Width: exact terminal width (cols × cellWidth)        │ │
│ │ - Height: exact terminal height (rows × cellHeight)     │ │
│ │ - Min height = screen height (short terminals fill it)  │ │
│ │ - SwiftTerm handles scrollback via internal scrolling   │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Why This Works

1. **TerminalView width = exact terminal width**: SwiftTerm renders all columns
2. **TerminalView height = exact terminal height**: SwiftTerm's `processSizeChange` sees a frame that matches the host terminal dimensions, so it never resizes the buffer
3. **Minimum height = screen height**: Short terminals fill the screen (no gap at bottom)
4. **Outer scroll view**: Handles horizontal scrolling for wide terminals AND vertical scrolling when the terminal is taller than the screen (e.g., a 65-row host on a ~53-row iPhone)
5. **SwiftTerm internal scroll**: Handles scrollback history navigation

### The Problem: SwiftTerm Auto-Resize Destroys Content

SwiftTerm's `layoutSubviews` calls `processSizeChange(newSize: bounds.size)`, which computes `newRows = height / cellHeight` and resizes the terminal buffer to match. When the host terminal has more rows than fit on the iOS screen (e.g., a 65-row macOS terminal on a ~53-row iPhone), SwiftTerm shrinks the buffer, destroying bottom rows including DECSTBM scroll region footers (see GitHub issue #244).

### The Fix: Content-Sized Terminal View

Instead of constraining the terminal view to the screen height and fighting SwiftTerm's auto-resize, the terminal view is constrained to match the terminal content height exactly:

```swift
// Height: at least screen height, prefers exact terminal height
terminalView.heightAnchor.constraint(
    greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor
)
let heightConstraint = terminalView.heightAnchor.constraint(
    equalToConstant: exactHeight
)
heightConstraint.priority = .defaultHigh
```

This ensures:
- **Short terminals** (rows fit on screen): `greaterThanOrEqualTo` fills the screen, SwiftTerm resizes to match — identical behavior to before
- **Tall terminals** (rows exceed screen): `equalToConstant` at `.defaultHigh` expands the view to fit all rows, SwiftTerm's `processSizeChange` sees the correct frame and preserves all rows including footers
- **No buffer corruption**: SwiftTerm never resizes the buffer to a smaller size, so no rows are destroyed
- **Natural scrolling**: The outer scroll view provides vertical scrolling to reach footer content, same as horizontal scrolling for wide terminals

### Previous Approach: Managed Terminal Size (Abandoned)

An earlier attempt used a `managedTerminalSize` property to restore terminal dimensions after SwiftTerm's `layoutSubviews` shrunk the buffer. This approach had fundamental issues:

1. **Buffer corruption**: The resize dance (65→53→65) during layout pushed rows to scrollback then pulled them back, corrupting buffer state
2. **Scroll position conflicts**: SwiftTerm's `updateScroller` and `scrolled(source:yDisp:)` callbacks reset `contentOffset` based on `displayBuffer.rows`, conflicting with our positioning
3. **cellHeight mismatches**: FontMetrics calculations differed slightly from SwiftTerm's internal `cellDimension`, making cursor-aware scroll positioning unreliable
4. **Complex workarounds**: Required overriding `sizeChanged`, `contentOffset`, `blockScrollChanges` flags, and async dispatch chains — all fragile and interdependent

The content-sized approach avoids all these issues by working WITH SwiftTerm's layout instead of against it.

## InteractiveTerminalView Subclass

Ctrlx extends SwiftTerm's `TerminalView` with `InteractiveTerminalView`:

### Features

1. **Keyboard Input Control**
   ```swift
   var inputEnabled = false
   override var canBecomeFirstResponder: Bool { inputEnabled }
   ```

2. **Scroll Preservation During Updates**
   ```swift
   var preserveUserScroll = false
   private var blockScrollChanges = false

   override var contentOffset: CGPoint {
       get { super.contentOffset }
       set {
           if blockScrollChanges { return }
           super.contentOffset = newValue
       }
   }
   ```

3. **Feed with Scroll Preservation**
   ```swift
   func feedPreservingScroll(_ bytes: ArraySlice<UInt8>) {
       if preserveUserScroll {
           let maxScrollY = max(0, contentSize.height - bounds.height)
           let isAtBottom = maxScrollY <= 0 || super.contentOffset.y >= maxScrollY - 5
           blockScrollChanges = !isAtBottom
       }
       feed(byteArray: bytes)
       blockScrollChanges = false
       setNeedsLayout()
   }
   ```

   This prevents new content from auto-scrolling when the user has scrolled up to read history.

## TerminalState Bridge

`TerminalState` is an `@Observable` class that bridges SwiftUI and UIKit:

| Property/Callback | Purpose |
|-------------------|---------|
| `onData` | Feed data to terminal |
| `onResize` | Handle dimension changes |
| `scrollToBottom` | Scroll terminal to bottom (callable from SwiftUI) |
| `makeTextSnapshot` | Capture retained local terminal text for the copy surface |
| `onInitialContentLoaded` | Called once after initial content is fed |

### Scroll-to-Bottom Implementation

Both the inner terminal (scrollback) and outer scroll view (tall terminal overflow) are scrolled:

```swift
terminalState.scrollToBottom = { [weak terminalView, weak scrollView] in
    guard let terminalView else { return }
    // Inner: scroll SwiftTerm's scrollback to bottom
    terminalView.scrollToBottom()
    // Outer: scroll to show the bottom of a tall terminal
    if let scrollView {
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        scrollView.contentOffset.y = maxY
    }
}
```

Called on:
- Initial content load (after 100ms delay for layout)
- Keyboard show (after 350ms delay for animation)

## Key Constraints and Limitations

### Text Selection Across the Outer Viewport

SwiftTerm owns its selection gesture and only auto-scrolls when the drag leaves the
`TerminalView` bounds. Gallager's `TerminalView` bounds cover the complete host-sized
terminal, while the iPhone shows only a smaller rectangle through the outer scroll view.
Reaching the phone edge therefore does not leave the terminal bounds, so SwiftTerm never
scrolls and the selection cannot extend into content outside the outer viewport. The same
ownership mismatch affects horizontal selection.

Resizing is not an appropriate copy workaround:

- Sending `ResizeTmuxPane` ultimately runs `tmux resize-window`, changing the shared tmux
  window for the Mac and every viewer.
- Resizing only the local SwiftTerm buffer makes it disagree with control sequences emitted
  for the host dimensions and reintroduces the buffer corruption described above.
- Multiple viewers would compete for the shared window size and require fragile restoration
  when a viewer disconnects.

The first-stage copy solution therefore keeps the terminal dimensions unchanged and creates
a static text snapshot from the local SwiftTerm buffer only when requested. A native read-only
text view owns selection in that snapshot, so iOS provides normal cross-screen selection,
copy, and Select All without a relay request. The live terminal remains the source of truth;
closing and reopening the copy view refreshes the snapshot.

The snapshot walks SwiftTerm's active scroll-invariant lines, including retained scrollback,
and removes only terminal cell padding on the right. It explicitly skips the null cells that
follow wide characters; SwiftTerm's generic buffer export does not do that and would put an
invisible NUL after Chinese or other double-width glyphs. Alternate-screen applications are
read from the active alternate buffer rather than stale normal-buffer history.

Only the selected pane contributes the toolbar action in a multi-pane layout. This avoids
duplicated toolbar items and makes the copied buffer unambiguous. The sheet receives an
immutable value: new terminal output continues normally but cannot move or invalidate the
user's current selection.

A later enhancement may teach the SwiftTerm fork about the outer visible rectangle and make
selection-handle drags scroll the outer view. That is a direct-manipulation improvement, not a
reason to change tmux sizing.

### SwiftTerm Limitations

| Limitation | Impact | Workaround |
|------------|--------|------------|
| No horizontal scrolling | Wide terminals clipped | Outer scroll view wrapper |
| contentOffset.x always 0 | Can't pan horizontally in terminal | Outer scroll view |
| Frame = terminal size expected | Can't make terminal smaller than buffer | Accept full-size frame |
| updateScroller() not overridable | Can't customize scroll behavior | Content-sized view avoids the need |

### Ctrlx Constraints

| Constraint | Reason |
|------------|--------|
| Terminal dimensions from Mac | Must display exact same content |
| Need horizontal scroll | Mac terminals often wider than phone |
| Need scroll preservation | Don't lose place when content updates |
| Single-scroll UX | Users expect one scroll gesture |

## Future Improvements

### Option: Contribute to SwiftTerm

To enable native horizontal scrolling:

1. Modify `updateScroller()` to preserve `contentOffset.x`
2. Modify `drawTerminalContents()` to offset rendering by `contentOffset.x`
3. Add configuration for horizontal scroll behavior

This would allow eliminating the outer scroll view entirely.

### Current Status

The content-sized terminal view approach works correctly for both short and tall terminals. SwiftTerm handles its own buffer sizing naturally, and the outer scroll view provides horizontal and vertical scrolling as needed. The complexity is minimal — just Auto Layout constraints in `TerminalStreamContainerView`.

## References

### SwiftTerm Source (from .build/checkouts/)

- `SwiftTerm/Sources/SwiftTerm/iOS/iOSTerminalView.swift`
- `SwiftTerm/Sources/SwiftTerm/Apple/AppleTerminalView.swift`

### Ctrlx Source

- `CtrlxPackage/Sources/CtrlxFeature/Views/LiveTerminalView.swift` - Main terminal view
- `CtrlxPackage/Sources/CtrlxFeature/Views/InteractiveTerminalView.swift` - SwiftTerm subclass
