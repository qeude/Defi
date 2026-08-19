---
status: accepted
---

# Keep macOS authoritative

Defi manages real third-party windows through public Accessibility APIs by
default and treats confirmed native focus together with the latest human focus
intent as authoritative. It will not require Screen Recording or simulate window
motion with captured overlays. An experimental private frame backend may mutate
third-party window position and size only after explicit user opt-in and
Defi-owned capability probing. It remains disabled by default and must fall back
to the public backend for the session after failure. Focus, lifecycle, Spaces,
Dock, Command-Tab, and modal behavior remain owned by macOS.
