# Runtime isolation

Window-management state does not live on the main thread. When it did, slow
applications (100-500 ms per Accessibility operation) shared the main thread
with snapshots and settlement, and command queue waits reached 2.7 s. Budgeting
and chunking bounded single sections but could not remove the shared thread.

## Ownership

- [`NavigationActor`](../../Sources/DefiRuntime/NavigationActor.swift) owns
  navigation and runtime state on its own serial queue. Commands, normalized
  native events, and Accessibility completions enter it as messages, in arrival
  order. Enqueue callbacks directly; an `await` that splits a state transition
  lets another message interleave.
- [`SnapshotEngine`](../../Sources/DefiMacOS/SnapshotEngine.swift) runs snapshot
  passes on a serial queue; its shared state is lock-guarded for main-thread
  readers.
- The main thread runs AppKit, NSScreen, event taps, observer run loops, and the
  overlay, because macOS requires it. It must stay microsecond-scale so keyboard
  intake remains responsive whatever applications do.
- Accessibility writes run on per-process queues, so one slow application cannot
  delay writes to another.

Structural Accessibility latency (applications accepting frames late) is a
macOS property handled by latency lanes, not by threading.

## Not done

The reducers in `DefiRuntime` still mutate `RuntimeState` in place and the
daemon performs platform effects directly. Returning effects as values from the
reducers would make the diagnostic journal replayable and let tests assert
emitted effects; it remains a direction, not current behavior.
