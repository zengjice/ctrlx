# SwiftTerm Terminal Sizing Analysis

This document details how SwiftTerm calculates terminal cell dimensions, view sizing, and internal padding. Understanding these calculations is critical for properly sizing mirror windows in Ctrlx.

> **SwiftTerm Version**: Commit [`6b61f16`](https://github.com/jicezeng/SwiftTerm/tree/6b61f169f1edb31d0beb14b2df5847e757737c12)

## Cell Size Calculation

SwiftTerm calculates character cell dimensions in the `computeFontDimensions()` method.

**File**: [`AppleTerminalView.swift`](https://github.com/jicezeng/SwiftTerm/blob/6b61f169f1edb31d0beb14b2df5847e757737c12/Sources/SwiftTerm/Apple/AppleTerminalView.swift)

```swift
func computeFontDimensions() -> CellDimension {
    let lineAscent = CTFontGetAscent(fontSet.normal)
    let lineDescent = CTFontGetDescent(fontSet.normal)
    let lineLeading = CTFontGetLeading(fontSet.normal)
    let cellHeight = ceil(lineAscent + lineDescent + lineLeading)

    // macOS approach: use glyph advancement for "W"
    let glyph = fontSet.normal.glyph(withName: "W")
    let cellWidth = fontSet.normal.advancement(forGlyph: glyph).width

    let scale = backingScaleFactor()
    let snappedWidth = (cellWidth * scale).rounded() / scale
    let snappedHeight = ceil(cellHeight * scale) / scale
    return CellDimension(width: max(1, snappedWidth), height: max(1, snappedHeight))
}
```

### Key Points

| Dimension | Calculation | Notes |
|-----------|-------------|-------|
| **Width** | `round(advance × scale) / scale` | Uses the "W" glyph and snaps to the nearest device pixel |
| **Height** | `ceil(ascent + descent + leading)` | Includes all font metrics, rounded up |

Both values are clamped to a minimum of 1 pixel.

### Ctrlx Implementation

Our `FontMetrics.calculateCellSize()` exactly mirrors this calculation:

**File**: [`CtrlxPackage/Sources/CtrlxCommon/Utilities/FontMetrics.swift`](../CtrlxPackage/Sources/CtrlxCommon/Utilities/FontMetrics.swift)

## Terminal View Sizing

When the TerminalView's frame changes, SwiftTerm recalculates how many columns and rows fit.

**File**: [`AppleTerminalView.swift`](https://github.com/jicezeng/SwiftTerm/blob/6b61f169f1edb31d0beb14b2df5847e757737c12/Sources/SwiftTerm/Apple/AppleTerminalView.swift)

```swift
func processSizeChange(newSize: CGSize) -> Bool {
    let newRows = Int(newSize.height / cellDimension.height)
    let newCols = Int(getEffectiveWidth(size: newSize) / cellDimension.width)

    if newCols != terminal.cols || newRows != terminal.rows {
        terminal.resize(cols: newCols, rows: newRows)
        // ...
    }
}
```

**Critical**: The width calculation uses `getEffectiveWidth()`, not the raw frame width.

## The Internal Scroller (Source of Horizontal Padding)

SwiftTerm's macOS implementation (`MacTerminalView`) includes an internal `NSScroller` for scrollback navigation. This scroller reserves horizontal space.

### Effective Width Calculation

**File**: [`MacTerminalView.swift`](https://github.com/jicezeng/SwiftTerm/blob/6b61f169f1edb31d0beb14b2df5847e757737c12/Sources/SwiftTerm/Mac/MacTerminalView.swift)

```swift
func getEffectiveWidth(size: CGSize) -> CGFloat {
    return (size.width - scroller.frame.width)
}
```

Compare with iOS which has no scroller:

**File**: [`iOSTerminalView.swift`](https://github.com/jicezeng/SwiftTerm/blob/6b61f169f1edb31d0beb14b2df5847e757737c12/Sources/SwiftTerm/iOS/iOSTerminalView.swift)

```swift
func getEffectiveWidth(size: CGSize) -> CGFloat {
    return size.width
}
```

### Scroller Setup

**File**: [`MacTerminalView.swift`](https://github.com/jicezeng/SwiftTerm/blob/6b61f169f1edb31d0beb14b2df5847e757737c12/Sources/SwiftTerm/Mac/MacTerminalView.swift)

```swift
func setupScroller() {
    let style: NSScroller.Style = .overlay
    let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: style)
    let scrollerFrame = NSRect(
        x: bounds.maxX - scrollerWidth,
        y: 0,
        width: scrollerWidth,
        height: bounds.height
    )
    // ...
}
```

SwiftTerm currently defaults to an overlay scroller. Its configured width is still
included in `getOptimalFrameSize()` while the scroller is visible.

## Why Ctrlx Needs a Horizontal Buffer

Ctrlx wraps `TerminalView` inside its own `NSScrollView` with overlay scrollers (which don't consume space). However, **SwiftTerm still reserves space for its internal scroller**.

This creates a mismatch:

```
┌─────────────────────────────────────────────────┐
│ Ctrlx NSScrollView (overlay scrollers)      │
│ ┌─────────────────────────────────────────────┐ │
│ │ SwiftTerm TerminalView                      │ │
│ │ ┌───────────────────────────────────┬─────┐ │ │
│ │ │ Effective content area            │Scrl │ │ │
│ │ │ (width - scrollerWidth)           │ 15px│ │ │
│ │ └───────────────────────────────────┴─────┘ │ │
│ └─────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

Without compensation, approximately **2 characters** get clipped on the right edge.

### Current Solution

We add a **20px horizontal buffer** to both the terminal frame and window content size:

**Terminal frame**: [`TerminalContainerView.swift` (lines 132-135)](../CtrlxPackage/Sources/CtrlxServerFeature/Views/TerminalContainerView.swift#L132-L135)

```swift
let horizontalBuffer: CGFloat = 20
let width = CGFloat(columns) * cellSize.width + horizontalBuffer
```

**Window size**: [`MirrorWindowManager.swift` (lines 45-48)](../CtrlxPackage/Sources/CtrlxServerFeature/Managers/MirrorWindowManager.swift#L45-L48)

```swift
let horizontalBuffer: CGFloat = 20
let contentWidth = CGFloat(paneInfo.width) * cellSize.width + horizontalBuffer
```

### Buffer Breakdown

| Component | Pixels | Notes |
|-----------|--------|-------|
| NSScroller (overlay) | system-defined | `NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)` |
| Layout safety margin | 4px | Covers fractional container sizing at grid boundaries |
| **Total** | **Scroller width + 4px** | Calculated at runtime |

## Alternative Approaches

### 1. Dynamic Scroller Width Calculation (Implemented)

Instead of hardcoding 20px, calculate dynamically:

```swift
let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
let horizontalBuffer = scrollerWidth + 4 // rounding buffer
```

This is the current implementation in `FontMetrics.horizontalBuffer`.

### 2. Disable SwiftTerm's Internal Scroller

Would require modifications to SwiftTerm or using a custom subclass. Not recommended unless contributing upstream.

### 3. Use SwiftTerm's Native Scrolling

Remove our NSScrollView wrapper and let SwiftTerm manage its own scrolling entirely. **See analysis below** - this is not feasible without modifying SwiftTerm.

## Feasibility Analysis: Removing the NSScrollView Wrapper

We investigated whether Ctrlx could remove its `NSScrollView` wrapper and use SwiftTerm's native scrolling directly. This would potentially eliminate the horizontal buffer hack entirely.

### Current Ctrlx Architecture

```
┌─────────────────────────────────────────────────────────┐
│ TerminalContainerView (NSViewRepresentable)             │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ NSScrollView (overlay scrollers)                    │ │
│ │ ┌─────────────────────────────────────────────────┐ │ │
│ │ │ FlippedClipView (isFlipped = true)              │ │ │
│ │ │ ┌─────────────────────────────────────────────┐ │ │ │
│ │ │ │ SwiftTerm TerminalView                      │ │ │ │
│ │ │ │ (with internal NSScroller)                  │ │ │ │
│ │ │ └─────────────────────────────────────────────┘ │ │ │
│ │ └─────────────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

| Component | Purpose |
|-----------|---------|
| `NSScrollView` | Container with overlay scrollers |
| `FlippedClipView` | Custom NSClipView with `isFlipped = true` for top-alignment |
| `TerminalView` | SwiftTerm's terminal (has its own internal scroller) |

### Why the Wrapper Exists

1. **Top Alignment**: SwiftTerm renders content bottom-up (standard AppKit). Ctrlx needs top-alignment.
2. **Overlay Scrollers**: Our NSScrollView uses overlay style (don't consume space).
3. **Fixed Sizing**: Precise control over terminal dimensions matching tmux pane.

### Blocking Issue #1: Bottom-Alignment is Hard-Coded

SwiftTerm's drawing code explicitly calculates Y coordinates from the bottom:

**File**: [`AppleTerminalView.swift`](https://github.com/jicezeng/SwiftTerm/blob/6b61f169f1edb31d0beb14b2df5847e757737c12/Sources/SwiftTerm/Apple/AppleTerminalView.swift)

```swift
let lineOrigin = CGPoint(x: 0, y: frame.height - lineOffset)
```

**File**: [`MacTerminalView.swift`](https://github.com/jicezeng/SwiftTerm/blob/6b61f169f1edb31d0beb14b2df5847e757737c12/Sources/SwiftTerm/Mac/MacTerminalView.swift) (mouse hit calculation)

```swift
let row = Int((frame.height - point.y) / cellDimension.height) + terminal.buffer.yDisp
```

**Impact**: Without our `FlippedClipView`, all content would render at the bottom of the window and fill upward - completely unusable for a terminal mirror.

There is **no configuration option** to change this behavior. It would require modifying SwiftTerm's source code.

### Blocking Issue #2: Internal Scroller Always Present

SwiftTerm's `MacTerminalView` always creates and reserves space for its internal `NSScroller`:

- Scroller uses `.overlay` style with a system-defined width
- `getEffectiveWidth()` always subtracts scroller width
- No API to disable or hide the scroller

Even without our wrapper, SwiftTerm would still reduce the effective content width.

### SwiftTerm's Scroll APIs

SwiftTerm does expose scroll functionality that works regardless of our wrapper:

| Method | Description |
|--------|-------------|
| `scroll(toPosition: Double)` | Set position (0.0 = top, 1.0 = bottom) |
| `scrollUp(lines: Int)` | Scroll up by line count |
| `scrollDown(lines: Int)` | Scroll down by line count |
| `scrollPosition` | Read current position |
| `canScroll` | Check if scrollable |

However, these don't help with the alignment or scroller space issues.

### Conclusion: Not Feasible

| Issue | Severity | Solution Required |
|-------|----------|-------------------|
| Bottom-alignment hard-coded | **Blocking** | Modify SwiftTerm source |
| Internal scroller always present | **Blocking** | Modify SwiftTerm source |
| Scroll state tracking | Medium | Refactor (doable) |

**Recommendation**: Keep the current architecture. The `NSScrollView` wrapper with `FlippedClipView` and dynamic horizontal buffer is the pragmatic solution given SwiftTerm's design constraints.

### Future Option: Contribute to SwiftTerm

To truly eliminate the wrapper, one could contribute upstream to SwiftTerm:

1. Add optional top-alignment mode (coordinate system flag)
2. Add option to disable/externalize the internal scroller
3. Expose scroller configuration

This would be significant effort for marginal benefit, given the current solution works correctly.

## Vertical Sizing

Vertical sizing is simpler - no scroller interference:

```swift
let height = CGFloat(rows) * cellSize.height
```

The window adds **110px vertical padding** for:
- Title bar: ~28px
- Toolbar: ~38px
- Status bar: ~28px
- Buffer: ~16px

## Detached terminal windows (Mac Local and Viewer)

Terminal Window labels can be dragged away from the tab strip, or opened
with **Open in Separate Window** in their context menu. This creates a native
`DetachedTerminalScene`, not another tmux Window or an Agent fork. A detached
scene reuses `MainView` without the session sidebar; it is a multi-tab workbench
for exactly one Host and Session.

`DetachedTerminalWindows` reserves presentation ownership using the Host pair ID
(nil for Local) plus tmux's stable `@window_id`. Older Host snapshots that only
provide `session:index` cannot detach. Each terminal appears in only its owning
native window's tab strip. Terminal, Files and Browser tabs can move between the
main workbench and detached workbenches for the same Host and Session, or reorder
within them. Cross-Host/session drops cannot merge workspaces. Git remains a
per-workbench utility; Simulator tabs are not transferable. Local simulator views
and read-only Host simulator tabs remain in the main workbench, without being
duplicated into every detached scene.

Closing the native window returns its terminal ownership and live Files/Browser
state to the main workbench without terminating tmux or reloading native browser
pages. Cmd-W retains the main workbench's explicit close-current-tab behavior.
There is no cross-launch restoration of detached scenes. While a session has
detached tabs, main-window persistence must not save its partial tab set over a
complete saved workspace; normal persistence resumes when tabs return.

Each scene has its own `TerminalQuickActionRouter`, while pane state, ordered
terminal streaming and Viewer connections remain shared. Existing pane layouts,
Questions and editor overlays are reused. New Terminal/Agent, Fork, Open Files,
Open Browser and terminal-link actions stay in the workbench that initiated
them. Each scene has its own selection and tab state; browser presentation can
move without changing the owning agent or native page identity. The toolbar and
tab menus are the same components as the main window, including icon-only Fit.

Workbench menu actions use scene-focused values, as Cmd-W already does; tab
navigation and Find in Files never broadcast to other native windows. Session
navigation and New Session are enabled only in the main workbench that owns the
sidebar. Previous/Next Tab follow the left tab strip's order, excluding right-side
tabs, and remain available when only Files/Browser tabs survive. Host browser
catalog removals repair a lost left selection even when no split was collapsed,
without stealing a still-valid selection or choosing a right-side tab.
Viewer-local browser closes perform the same selection repair only after removing
the tab and applying parent/origin return, so cleanup cannot erase the fallback.
Find in Files reuses the selected directory tab before requiring a source terminal
to create one. With no left terminal, Git takes the selected Files directory and
then retains its existing store path across tab changes; mouse and keyboard
selection use the same directory resolver. A live terminal's cwd still takes
precedence. Moving an existing Git tab between split sides retains its store;
only a missing store needs the shared directory resolver, never an empty window
ID lookup that falls back to Home. Git's left-side selection belongs to the workbench's session tab
state, not a terminal ID. Pane metadata refresh and terminal reindexing cannot
clear it or select a Files fallback over it. Explicit left-side Terminal, Files
or Browser selection leaves Git; selecting a right-side terminal does not.

Terminal selection is scoped to the owning native window and excludes that
window's right-side tabs. Split moves, detach/transfer, session selection and
terminal removal use the same left-selection rule; closing a terminal rechecks
ownership, including after process inspection. The session context survives an
empty terminal selection, so Files/Browser tabs and the New Tab menu remain
available after the last owned terminal exits while the tmux session still
exists elsewhere. New terminals and compatible drops can rejoin that workbench
without resolving its now-dead original pane. Session rename migrates both the
tab dictionaries and retained session names, even without a selected terminal;
remote migrations also match the Host ID. Files/Browser selection and live
content are retained; if needed, the first remaining left-side private tab is
selected. Fit can still target a right-side terminal when the left side has no
terminal. Terminal file links likewise validate the source pane against the
current session and native-window ownership before and after resolution, not
against a required left terminal selection.

Every Mac Viewer scene observes the Host's pane/session/window routing identity.
It infers renames with the same complete-pane-set rule as Local. Before any scene
reconciles the renamed browser catalog, `DetachedTerminalWindows` synchronously
migrates all tab stores and detached-workspace names for that Host / Session,
including the main window's store. This preserves explicit browser ownership
after a tab moves between windows, regardless of which scene observes the rename
first. Local renames use the same shared migration; repeated calls are idempotent,
and other Hosts / Sessions are untouched. Each scene still migrates its own
selection and persistence bookkeeping before pruning stale entries. The rename-command
callback no longer migrates only its initiating scene. Agent activity, titles,
cwd and dimensions do not change this structural identity; disconnects and
partial window moves are not guessed to be renames.
The same observer reconciles Host browser and simulator catalogs after migration, using the
current session selection rather than a detail-view callback captured before
the rename. Catalog and pane delivery may span separate renders: reconciliation
waits when a source pane's session disagrees with either descriptor. Both
split surfaces include the descriptor's session name in their view identity so
a late catalog cannot leave an owned remote browser or simulator session targeting the old
name. Browser tab IDs, ordering, split placement and selection remain unchanged.

Entering a terminal tab requests one automatic Fit after its viewport is ready,
including in a detached workspace. Closing Files or a browser back to a terminal
also fits once; returning to another file/browser tab does not. Passive geometry
changes, moving, enlarging or entering fullscreen do not schedule another Fit.
After resizing, the next ordinary single click in terminal content fits that
terminal's owned tmux window once, using the current scene/split viewport. Repeated
clicks with the same successfully fitted target grid do not fit again. Manual and
automatic Fit invalidate the planned targets' previous baselines, then record each
target only after its resize succeeds. Failed and unattempted targets remain retryable
by a new click; geometry/snapshot updates alone never retry them. Each plan captures
its Host, session and window before awaiting, so completion cannot update a newly
selected target's baseline. Hosts, tabs and scenes keep separate baselines.
With workspace identities, the plan also retains its original physical window.
The Host checks that identity in the tmux queue both when reading the layout and
when applying the resize. A restarted server or reused window ID rejects the old
plan; selecting another pane in the same live window does not. Viewer automatic
Fit waits for usable identity metadata before consuming its pending request.
The click waits for the system double-click interval and excludes drag/word/row
selection, links, modifiers, mouse-reporting terminal apps, voice holds and IME
composition. Typing, scrolling, hiding/removing the terminal or losing focus cancels
the delayed action. Clicking Files or browser content does not fit a terminal.
Activating the owning window requests one Fit for its displayed terminal,
preferring the focused terminal when split; inactive windows wait. The Host skips
resizing when live tmux dimensions match the request; a cached client layout
cannot suppress it.
The **Fit** button uses the independent scene's terminal area, excluding its tab
strip. Both manual and automatic Fit respect terminal ownership, so the main
window cannot resize detached Windows. Detached workspaces use their transferred
tab state immediately instead of waiting for main-window layout persistence.
AppKit handles native screen/backing-scale changes; focusing an off-screen window
recenters it.

Native tab dragging exports a `WorkbenchTabDrag` envelope containing the source
scene, Host and Session plus the existing `TabDragPayload`; the receiving
workbench checks the scope before transferring state. The legacy payload is
also exported for isolated tab-strip consumers. In-strip ordering and split drop
targets keep their existing behavior. Only an
unclaimed mouse release more than 24 points above/below the source tab row or
beyond the source window's horizontal edge detaches. Dropping over the terminal
inside a maximized main window therefore works. The row extends across the
window for this test so horizontal reordering, including empty slots and the
other split's tabs, never detaches. Escape, accepted drops, and small vertical
movements do not detach. The source records the mouse-up event's location,
converted through that event's window (windowless events already use screen
coordinates), never the current global pointer position. A delayed AppKit
completion must not mistake a later mouse-move for cancellation
or use its location as the drop point.

## References

### SwiftTerm Source Files

- [AppleTerminalView.swift](https://github.com/jicezeng/SwiftTerm/blob/6b61f169f1edb31d0beb14b2df5847e757737c12/Sources/SwiftTerm/Apple/AppleTerminalView.swift) - Shared Apple platform code
- [MacTerminalView.swift](https://github.com/jicezeng/SwiftTerm/blob/6b61f169f1edb31d0beb14b2df5847e757737c12/Sources/SwiftTerm/Mac/MacTerminalView.swift) - macOS-specific implementation
- [iOSTerminalView.swift](https://github.com/jicezeng/SwiftTerm/blob/6b61f169f1edb31d0beb14b2df5847e757737c12/Sources/SwiftTerm/iOS/iOSTerminalView.swift) - iOS implementation (for comparison)

### Ctrlx Source Files

- [FontMetrics.swift](../CtrlxPackage/Sources/CtrlxCommon/Utilities/FontMetrics.swift) - Cell size calculation
- [TerminalContainerView.swift](../CtrlxPackage/Sources/CtrlxServerFeature/Views/TerminalContainerView.swift) - Terminal view wrapper
- [MirrorWindowManager.swift](../CtrlxPackage/Sources/CtrlxServerFeature/Managers/MirrorWindowManager.swift) - Window sizing logic
