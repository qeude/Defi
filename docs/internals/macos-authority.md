# macOS authority

Defi manages real third-party windows through public Accessibility APIs and
treats confirmed native focus together with the latest human focus intent as
authoritative. Focus, lifecycle, Spaces, Dock, Command-Tab, and modal behavior
remain owned by macOS.

Motion is drawn from captured window pictures on a Defi-owned overlay, and the
real windows move underneath it through Accessibility (see
[ribbon motion](./ribbon-motion.md)). The overlay only draws: navigation, focus,
and window movement never depend on capture or on Screen Recording, and without
the permission windows move at once. The Overview degrades to cards in the same
case (see [Overview capture](./overview-capture.md)).

## Activation

Defi follows an application activation without a recent click, such as a link
opened from another app. It resolves the activated window for at most two
seconds, only while that app is still frontmost, and drops the resolution on
newer focus input or a newer Defi command. An activation cannot prove a human
caused it, so one that would switch workspaces also needs user input newer than
the latest Defi command. When the Accessibility read fails, Defi retries the
read and never reuses a previous window.

Defi suppresses an activation that matches its own focus request while that
write is outstanding or has failed; only a click on that window lifts the
suppression. After the write succeeds, keyboard focus input newer than its
completion, such as Command-Tab, lifts it, and older input does not.

## Firm limits in shipped builds

- Third-party window position and size change only through public Accessibility.
  A private frame backend was evaluated, could not move third-party windows, and
  was removed.
- Defi works with System Integrity Protection enabled.
- Defi injects no code into another process.

## Private APIs

Other private APIs ship when they are optional read-only metadata, read-only
captures, reading the global hotkey operating mode, or calls on Defi-owned
surfaces. Symbols are resolved dynamically, and every use has a fully
functional public fallback.

Prototypes may try any other private API within the last two limits. One ships
only with a gain measured beyond noise and a complete public fallback, and this
page records why.
