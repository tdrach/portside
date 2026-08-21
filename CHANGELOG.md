# Changelog

## 0.3.0 — 2026-08-21
- Memory readout on every running row: the resident footprint of the
  server's whole process tree (npm → node → workers), sampled on the
  existing scan cycle. Quiet gray normally, amber past 2 GB, red past
  6 GB — a leaky dev server is now impossible to miss. Project rows
  show the summed footprint of their members.
- Diagnostics now include total and peak memory across server trees.
- Report an issue / Check for updates in the ⋯ menu.

## 0.2.0 — 2026-08-20
- Signed with Developer ID and notarized by Apple — installs cleanly with no
  Gatekeeper warnings; tickets stapled to both the app and the disk image so
  it validates offline
- Projects: group servers into a stack that starts and stops as one unit —
  one row, click to unfurl members, optional ordered start that waits for
  each member's port before launching the next
- Liquid Glass popover chrome (native macOS 26 API) with continuous 20pt corners
- Battery-style status chips: click to start/stop, hover crossfades to the
  action glyph, running chips warm to orange before a stop
- Version shown in the ⋯ menu; "Copy diagnostics" for bug reports
- Chrome kill switch: `defaults write design.subtract.portside PortsideClassicChrome -bool YES`
- TCC purpose strings for project-file probes under Desktop/Documents/Downloads
- System Settings-style editor window; opening it dismisses the popover

## 0.1.0 — 2026-08-05
- Initial release: auto-discovery via lsof + syscalls, restart-recipe
  adoption, process-group stops with verified escalation, tombstoned
  removal, login-shell environment capture, 110-test suite
