# Simulator gestures

## Long press and drag

```sh
ctrlx simulator long-press --device <id> --identifier message.row --duration-ms 700
ctrlx simulator drag --device <id> --identifier draggable.item \
  --end-x 260 --end-y 500 --hold-ms 500 --duration-ms 300
ctrlx simulator swipe --device <id> --x 196 --y 650 \
  --end-x 196 --end-y 250 --duration-ms 350
```

Defaults: tap holds 20 ms; long press 650 ms; drag holds 500 ms, moves 300 ms.
`--duration-ms`: 20...5000; `--hold-ms`: 0...5000. Coordinates are logical points
from the display's top-left, excluding letterbox. Swipe uses coordinates. Human
input cancels agent gestures/revokes the writer; reclaim only when asked to continue.

For system gestures add `--edge top|left|bottom|right`, the current screen's origin
edge. Start one point inside and move inward; example for a 393 x 852 display:

```sh
ctrlx simulator swipe --device <id> --edge bottom --x 196.5 --y 851 \
  --end-x 196.5 --end-y 383.4 --duration-ms 300
```

Read geometry first: rotation transforms contacts and edges. Verify navigation;
the app and iOS decide the gesture's effect.

## Basic pinch

```sh
ctrlx simulator pinch --device <id> --x 196 --y 400 --scale 2 --duration-ms 500
ctrlx simulator pinch --device <id> --x 196 --y 400 --scale 0.5
```

`--x` / `--y` are the center in current display logical points. `--scale` is
final divided by initial finger spacing: greater than 1 spreads fingers, less
than 1 brings them together. Range: 0.25...4, excluding 1. Duration defaults to
500 ms, range 20...5000. No element selector, endpoint, edge or hold options.

Both contacts go down, move and lift together. The pair starts horizontal on the
current display, centered at the chosen point; initial spacing is up to 100 points
and shrinks to fit both endpoints. Centers too close to an edge are rejected.
Rotation is mapped through the same geometry validation as single-contact input.
Human takeover, closure or input failure releases held contacts; no gesture is
replayed. Observe the app's zoom result, which need not equal the requested finger
spacing ratio. This does not implement arbitrary two-finger paths or rotation.
