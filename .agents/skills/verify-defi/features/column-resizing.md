# Native column resizing

## Sub-features

- Horizontal edge drag on a tiled window becomes the column width (`columnWidth=pixels:<n>`). Following columns reflow and stacked siblings take the same width.
- Vertical edge drag is not persisted. On release the stack returns to equal automatic heights.
- Defi does not write the gestured window while the button is down. At release it reconciles the final observed frame.
- App width bounds survive the gesture. A bound is dropped only when the observed frame contradicts it. A user width never becomes a bound.
- The learned width survives workspace navigation and daemon restart.

## How to get to it (user POV)

Drag the right or left edge of a tiled window with the mouse, at ordinary speed, and release. Drag the bottom edge of a stacked window for the vertical case.

## Driving it with a real drag

Synthetic `defi` commands do not exercise this path. Post real mouse events instead. Build a throwaway helper outside the repo; its process needs Accessibility to post events:

```swift
// drag.swift: ./drag frames <OwnerName> | ./drag drag x0 y0 x1 y1 [ms]
import CoreGraphics
import Foundation
let a = CommandLine.arguments
if a[1] == "frames" {
  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
  for w in list where (w[kCGWindowLayer as String] as? Int) == 0
    && (w[kCGWindowOwnerName as String] as? String) == a[2] {
    let b = w[kCGWindowBounds as String] as! [String: Double]
    print(w[kCGWindowNumber as String]!, Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!))
  }
  exit(0)
}
let p = a[2...5].map { Double($0)! }; let ms = a.count > 6 ? Double(a[6])! : 600
func post(_ t: CGEventType, _ x: Double, _ y: Double) {
  CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: CGPoint(x: x, y: y),
    mouseButton: .left)!.post(tap: .cghidEventTap)
}
post(.mouseMoved, p[0], p[1]); usleep(150_000)
post(.leftMouseDown, p[0], p[1]); usleep(120_000)
let steps = max(Int(ms / 16), 1)
for i in 1...steps {
  let f = Double(i) / Double(steps)
  post(.leftMouseDragged, p[0] + (p[2] - p[0]) * f, p[1] + (p[3] - p[1]) * f); usleep(16_000)
}
usleep(120_000); post(.leftMouseUp, p[2], p[3])
```

Journey, under `python3 script/desktop_lock.py --wait bash`:

```sh
swiftc -O drag.swift -o drag                      # in the scratch directory holding drag.swift
defi status > before.status                       # note workspace=
defi focus-workspace-position <trailing-empty>    # keep the user's workspaces untouched
open -na TextEdit; sleep 1; osascript -e 'tell app "TextEdit" to make new document'; sleep 1
./drag frames TextEdit                            # id x y w h, two columns
./drag drag <x+w-2> <y+h/2> <x+w+150> <y+h/2> 600 # right edge of the left column, +150 px
sleep 1; defi status | tr ' ' '\n' | grep -E '^(columnWidth|drift|resize)='
./drag frames TextEdit                            # left w grew ~150, right column x moved by the same
defi focus-workspace down; defi focus-workspace up; sleep 1; ./drag frames TextEdit  # width kept
```

Vertical: `defi join-window left` (from the right column) to stack the two windows, drag the shared horizontal edge 150 px, release, and confirm both heights return to equal halves.

Pass: `columnWidth=pixels:<w+150 plus gaps>` after the drag, the neighbor reflowed once, `drift=0[]`, `resize=none`, no repeated size corrections for the window in `defi trace` after release, width unchanged after the workspace round trip, vertical drag leaves no persistent height split. Close the TextEdit documents without saving and restore `workspace=` from `before.status`.

## Gotchas

- A plain `osascript` resize is app-driven, not a user gesture: it goes through constraint learning, not width learning.
- Release inside the poll interval of a drag can settle up to 0.25 s later (0.8 s for latency-sensitive apps). Sleep before reading `status`.
- Dragging back to the start width within one gesture is a cancellation; the column must end at the start width, not an intermediate one.
- Maximized columns and intrinsic-size windows refuse width learning by design; the window is restored to its target on release.
- Covering pure tests: `RuntimeWidthLearningTests` (`Mouse resize …`, `Height only resize …`, `Stacked column …`), `MouseReorderingTests` (`Post release settlement ignores a late frame matching a Defi write`), `DaemonCommandPolicyTests.userHeldGestureWidthDoesNotAgeIntoConstraint`.
