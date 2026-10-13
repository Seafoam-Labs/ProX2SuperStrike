# PX2 GTK configuration editor

`px2-gui` is the native Zig 0.16 / GTK4 editor, included by default, using Ghostty's generated GObject bindings. It uses the existing `px2` executable for every device operation, including locking, backups, CRC validation and desired-state persistence. The GUI itself never edits `desired.json` or onboard sectors.

## Build and run

GTK 4.12 or newer development files and pkg-config are required; the implementation is tested on GTK 4.24.1. The first GUI build fetches the pinned Ghostty bindings. CLI-only builds do not require GTK or fetch those bindings.

```sh
zig build
zig build run-gui
# Or:
./zig-out/bin/px2-gui
```

The GUI prefers the `px2` executable beside it. Use `--cli /path/to/px2` to select another build. `--help` lists options. `--state-dir`, `--backup-dir`, `--device`, and `--connection auto|direct|receiver` are forwarded as separate arguments to every backend operation. State directories must be absolute. Different state directories get independent application instances; opening the same default application presents its existing window.

The GUI does not install permissions or start a privileged process. Install the project's udev rule as described in the main README, then reconnect the mouse.

## Editing

Select a discovered profile in the sidebar, or use the compact profile picker in a narrow window. Browsing a profile does not activate it. Use **Activate profile** explicitly; inactive DPI and rate edits preserve the current active selection.

DPI edits set both X and Y. Existing unequal values are displayed separately. Supported ranges, steps, polling rates and HITS limits come from the snapshot. HITS controls are available only for the active profile; left and right button edits are independent. Haptics zero means off. Only fields you change are submitted, preserving unset restoration fields.

Changes are staged until **Apply changes**. **Discard** reloads the last snapshot values. Navigation with pending edits opens a confirmation; cancelling keeps the current draft. Profile initialization first runs the CLI dry run, then opens a separate write confirmation. Backup paths appear under Diagnostics.

Before Apply, the editor rechecks watcher state and the device snapshot. If values changed externally, it retains your draft and asks you to review the refreshed state, Apply again, or Discard. Each CLI command holds the existing device lock, but a sequence of commands is not atomic and does not provide compare-and-swap against other tools.

If a command fails, the sequence stops and readback reconciles completed changes. Remaining edits stay pending. A failed readback disables Apply until a successful Refresh. Writes are never automatically retried or force-killed on window close; a busy window asks you to wait.

## Restoration and diagnostics

The restoration view distinguishes watcher process presence from its historical phase. It shows desired selection, connection preference, the last restore timestamp, and errors. For a custom state directory, run a watcher with the same `--state-dir`; the default systemd service may use another directory.

The connection selector applies to subsequent commands. PX2 persists the restriction after a successful active-profile setting change or activation, matching CLI behavior. Choosing Automatic clears the restriction on the next such operation.

Initial load, explicit Refresh, preflight checks and post-write reconciliation query the mouse. Background updates monitor local state and device connection events, and check local watcher presence every five seconds. They do not send periodic HID snapshots. A connection change marks cached data unavailable for writes and prompts Refresh; reconnecting never submits a draft automatically.

Saved DPI/rate are labeled as saved values. Reported firmware getters appear only in Diagnostics and may be stale. Successful writes and restoration transactions do not establish that physical pointer behavior matches live settings.

## Appearance and installation

Choose Pearl dark, Pearl light or System GTK in the header. Pearl modes use the reviewed palette; System GTK inherits the desktop's widget colors. Appearance and window size are stored atomically in `$XDG_CONFIG_HOME/px2/gui.json`, with the normal `~/.config` fallback. The GUI does not read Pearl's private configuration or automatically synchronize custom Pearl theme packages.

```sh
# Direct install, preserving your saved profile:
./packaging/install.sh
# Also activate a profile after installing:
./packaging/install.sh 1
# Arch build with the GUI included:
cd packaging/arch
makepkg -si
```

The default build, installer and Arch package include the GUI, desktop launcher and scalable icon alongside the matching CLI. For CLI-only use, select `zig build -Dgui=false`, `./packaging/install.sh --no-gui`, or `PX2_BUILD_GUI=0 shelly build --check PKGBUILD` (also supported with makepkg). Use `-Dgui=false` on Zig test commands too when building without GTK or binding downloads. Package installation and hardware changes are not part of the test suite.

Native [screenshots](native/README.md) show the implemented editor in both Pearl palettes, System GTK, and a narrow window.

## Verification

```sh
zig build test
zig build test-gui
python3 tests/watch_smoke.py
zig build smoke-gui                 # requires a GTK display
python3 tests/gui/headless.py        # private gtk4-broadwayd display
```

Native integration uses `tests/gui/fake_px2.py` with temporary directories and fictional data. It checks staged Apply, cancel/discard, inactive-profile writes, active HITS, sparse HITS arguments, initialization, partial failure, conflict detection, close during a slow write, missing CLI/device, permission errors, malformed/incompatible/oversized responses and corrupt desired state. The smoke driver requires both an explicit fake CLI and its fixture environment; it is not used during ordinary startup.

GUI model/protocol tests run without GTK. Native tests exercise real GTK widgets and asynchronous subprocesses. Physical USB/receiver behavior, suspend/wake recovery, assistive-technology interaction, and the GTK 4.12 runtime baseline still require hardware or target-environment acceptance. The existing CLI's hardware validation instructions remain applicable.
