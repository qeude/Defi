---
status: accepted
---

# Keep macOS authoritative

Defi manages real third-party windows through public Accessibility APIs and
treats confirmed native focus together with the latest human focus intent as
authoritative. Navigation, focus, and window movement never require Screen
Recording; the Overview may use it for window previews (ADR 0003) and degrades
to cards when it is unavailable. Native windows are never simulated with
captured overlays during scrolling.

Private APIs are limited to optional read-only metadata, such as WindowServer
geometry or corner radii, and to Defi-owned surfaces such as border overlays.
Symbols are resolved dynamically, and every lookup has a fully functional public
fallback. Third-party window position and size are never mutated through
private APIs: a private frame backend was evaluated, could not move third-party
windows, and was removed. Focus, lifecycle, Spaces, Dock, Command-Tab, and
modal behavior remain owned by macOS.
