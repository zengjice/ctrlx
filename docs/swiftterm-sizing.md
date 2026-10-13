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
`DetachedTerminalScene`, not another tmux Window or an Agent fork. Files and
Browser tabs are not detachable in this first implementation.

`DetachedTerminalWindows` reserves presentation ownership using the Host pair ID
(nil for Local) plus tmux's stable `@window_id`. Older Host snapshots that only
provide `session:index` cannot detach. Main-view terminal tiles become a
placeholder while their independent scene is open; their tab entries still
focus that scene. Closing the native window (including Cmd-W) releases only
presentation ownership, and **Return to Main Window** also selects its entry.
There is no cross-launch restoration of detached scenes.

Each detached scene keeps a single selected tab with the same label and styling
as the main window. Its tab context menu contains **Open Files in Main Window**,
**Fork**, and **Return to Main Window**; there is no separate toolbar `Window`
menu. The toolbar shares the main window's icon-only Fit button and help text.

Each scene has its own `TerminalQuickActionRouter`, while pane state, ordered
terminal streaming and Viewer connections remain shared. Existing pane layouts,
Questions and editor overlays are reused. Files, Fork and terminal-link actions
carry the captured Host / stable Window / pane context back to the main
workbench; they do not consult whichever tab was previously selected there.

The explicit-Fit rule also applies here: moving, enlarging or entering fullscreen
does not implicitly resize tmux. The **Fit** button uses the independent scene's
terminal area, excluding its tab strip. Main-window Fit excludes detached Windows,
preventing two presentations
from competing over the same tmux dimensions. AppKit handles the native window's
screen / backing-scale changes; focusing an off-screen window recenters it.

Native tab dragging exports the existing `TabDragPayload` representation so
in-strip ordering and split drop targets keep their existing behavior. Only an
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
