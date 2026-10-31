---
status: accepted
---

# Keep macOS authoritative

Defi manages real third-party windows through public Accessibility APIs and
treats confirmed native focus together with the latest human focus intent as
authoritative. Focus, lifecycle, Spaces, Dock, Command-Tab, and modal behavior
remain owned by macOS.

Motion is drawn from captured window pictures on a Defi-owned overlay, and the
real windows move underneath it through Accessibility. The overlay only draws:
navigation, focus, and window movement never depend on capture or on Screen
Recording, and without the permission windows move at once. The Overview degrades
to cards in the same case (ADR 0003).

Three limits are firm in shipped builds:

- Third-party window position and size change only through public Accessibility.
  A private frame backend was evaluated, could not move third-party windows, and
  was removed.
- Defi works with System Integrity Protection enabled.
- Defi injects no code into another process.

Other private APIs ship when they are optional read-only metadata, read-only
captures, or calls on Defi-owned surfaces. Symbols are resolved dynamically, and
every use has a fully functional public fallback.

Prototypes may try any other private API within the last two limits. One ships
only with a gain measured beyond noise, a complete public fallback, and an ADR
recording the decision.
