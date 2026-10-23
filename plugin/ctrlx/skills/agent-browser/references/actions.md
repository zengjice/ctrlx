# Bounded action details

Use `ctrlx browser action <operation> --tab <id> ...`. Lifecycle, `read`, `wait`
and `scroll` keep the CtrlX contract regardless of the selected engine.

`open --url` always creates a new owned page, even for the same URL. `open --new`
remains a compatibility alias. Inspect `tabs` and use `navigate --tab <id> --url`
to navigate an existing page. Page navigation/actions retain owner and control
checks; opening another page never releases a human's control of an existing tab.
Do not retry a timed-out open blindly; inspect `tabs` first.

## Read and pagination

`read` optionally scopes to `--selector`. Its `controls` list includes interactive
controls and readable/named regions (`kind: region`) so wait/scoped reads need no
guessed selectors; scroll containers include `scroll` position/extents. It includes
ordinary input values, focus/disabled/readonly/checked state and select options.
Follow non-null `nextTextOffset`/`nextControlOffset` with
`--text-offset`/`--control-offset`; limits are `--text-limit` (1–20000) and
`--control-limit` (1–100). Option lists cap at 100, control values at 2000
characters; truncation is explicit. Bounded read omits sensitive field values.

## Input and controls

`press` targets page focus; the original `--engine ctrlx` also accepts `--selector`
to focus one element first. Keys: Enter, Tab, Escape, Space, arrows (`ArrowLeft`
etc.), Home/End, PageUp/PageDown, Backspace/Delete; modifiers Shift/Control/Alt/Meta,
e.g. Shift+Tab. Meta+A selects all on Mac. Clipboard/browser shortcuts and arbitrary
printable keys are blocked; use `type`/`fill` for text.

```sh
ctrlx browser action type --tab <id> --selector '<observed-selector>' --text 'text'
ctrlx browser action fill --tab <id> --selector '<observed-selector>' --text 'replacement'
ctrlx browser action press --tab <id> --key Enter
ctrlx browser action select --tab <id> --selector '<observed-select>' --value '<observed-option-value>'
ctrlx browser action check --tab <id> --selector '<observed-checkbox>' --checked true
```

`type` inserts at the caret; `fill` replaces (empty text clears). Neither submits.
`action select` accepts one value. In the original engine it is native single-select
only and its input/change events are synthetic. Original `check` sets a native
checkbox/radio idempotently with a real click; unchecking a radio requires selecting
another. Custom widgets may need normal clicks. Vercel extended commands additionally
support multi-value select; see [page commands](page-commands.md).

## Scroll and wait

```sh
ctrlx browser action scroll --tab <id> --delta-y 600
ctrlx browser action wait --tab <id> --selector '<observed-selector>' --state visible --text 'Done' --timeout-ms 5000
```

`scroll` accepts optional container `--selector` and ±10000 CSS-pixel deltas.
`wait` defaults to page ready, or visible when a selector is given. States:
ready (no selector), attached/visible/hidden/enabled (unique selector). Optional
`--text` matches element text, not input value; unavailable for ready/hidden.
Timeout defaults to 5000 ms, maximum 10000; it follows same-tab navigation.
