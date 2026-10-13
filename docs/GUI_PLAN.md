# PX2 GTK GUI implementation plan

Add a `px2-gui` desktop application, included by default, in Zig 0.16, using GTK4 through Ghostty's generated GObject bindings. Use Pearl's base Material colors and geometry, and delegate device operations to the existing `px2` CLI. This keeps the current locking, backups, CRC checks, and restoration behavior authoritative.

Review the [interactive mockup](mockups/index.html), [dark preview](mockups/px2-dark.png), and [light preview](mockups/px2-light.png). The mockup uses fictional device data and in-memory edits. The native implementation is now available; see the [GUI guide](GUI.md) for shipped behavior and remaining acceptance checks. “gkt” is interpreted as GTK.

## Scope and behavior

The first release configures one SUPERSTRIKE per state directory, matching the existing backend. It supports cable and receiver connections, profile selection and activation, DPI, supported polling rates, left/right HITS, factory initialization, and restoration diagnostics. Profile names stay `Profile N`: the backend has no naming feature. Firmware updates, macros, button remapping, multiple simultaneous mice, and editing arbitrary JSON are outside this release.

| Area | Controls and behavior |
| --- | --- |
| Profiles | Discover slots from `snapshot.profiles`; distinguish the selected editor slot from the active intent. Browsing an inactive profile never activates it. Offer a separate **Activate profile** action. |
| Sensitivity | One linked X/Y DPI entry with optional common-value shortcuts; show existing X/Y separately when unequal. Validate against `supported.dpi` including step. Saving uses the current CLI's linked-axis setter. Populate rates from `supported.rates_hz`, never from a fixed device assumption. |
| Buttons and HITS | Left and right tabs, integer controls for actuation, rapid trigger and haptics. Limits come from device capabilities; zero means haptics off. Submit only changed fields so unset restoration values remain unset. HITS can be edited only for the active profile. |
| Restoration | Show watcher process presence, saved selection, connection preference, last recorded phase, last successful restore and errors. Process presence uses `running`, not historical `last_status.phase`. The watcher continues after the GUI closes. |
| Diagnostics | On-demand `doctor`, saved versus reported values, profile health, last operation results and backup paths. Explain permission failures with the existing udev installation instructions. |

Use staged edits with **Discard** and **Apply changes**. The footer states whether changes affect onboard DPI/rate or active-button HITS. Switching profiles, sections or buttons with unsaved changes offers **Keep editing** or **Discard changes**. Saving an inactive profile must leave the active profile unchanged. Factory-only slots show their saved values but disable writes until the user reviews and confirms **Initialize from factory**. Corrupt or unsupported profile data stays read-only with its actual reason.

An Apply operation can issue more than one CLI command, so it is **not atomic**. Run changed commands sequentially, stop on the first failure, refresh the result, and retain unapplied edits. Never announce that all changes succeeded after a partial failure. A failed command may already have changed the device; reconcile its outcome before offering retry. Sliders never write while being dragged.

## Pearl design

Use the semantic palette in the local Pearl checkout's `src/theme/theme.zig`, with the native control and sidebar geometry in `subprojects/dome/resources/style.css`. The inspected Pearl commit is `d4ea6c3`; PX2 is `a449724`. These are provenance references, not build dependencies on an absolute home directory.

| Token | Dark | Light |
| --- | --- | --- |
| Surface | `#141218` | `#fdf7ff` |
| Sidebar | `#1d1b20` | `#f7f2fa` |
| Card | `#211f26` | `#f3edf7` |
| Raised surface | `#2b2930` | `#ece6f0` |
| Text | `#e6e0e9` | `#1d1b20` |
| Secondary text | `#cac4d0` | `#49454f` |
| Accent | `#d0bcff` | `#6750a4` |
| Selected surface | `#4f378b` | `#eaddff` |

Use opaque surfaces, 12 px cards, 10 px buttons, Pearl's 2/4/8/12/16/24 spacing scale, symbolic icons, and the system GTK font. The prototype requests Inter/Noto Sans. Keep a compact device summary above a profile list; the main pane holds the editor with a persistent action footer. At narrow widths the sidebar becomes a profile selector and the footer wraps. Preserve keyboard focus, native accessible names, numeric slider values, 200% text scaling and reduced-motion settings. Status must remain understandable without color.

Production appearance options: **Pearl dark**, **Pearl light**, and **System GTK**. Default to Pearl dark for the initial design; retain the last user selection in GUI-only preferences. System GTK uses layout-only CSS so user theme colors and fonts apply. Automatic synchronization with Pearl's custom theme packages is deferred until a supported palette export contract is identified; do not read Pearl's private settings or assume a theme D-Bus API. Scope application styles under `.px2-root`.

## Dependencies and build

Ghostty maintains [generated GObject bindings](https://github.com/ghostty-org/zig-gobject); its [generator manifest](https://github.com/ghostty-org/zig-gobject/blob/main/build.zig.zon) currently declares Zig 0.16. The local Pearl build already consumes a Ghostty-generated archive:

```zig
.gobject = .{
    .url = "https://deps.files.ghostty.org/gobject-2026-07-28-36-1.tar.zst",
    .hash = "gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3",
    .lazy = true,
},
```

Use this as the candidate pin for a compatibility spike, verifying the archive and hash with the project's exact Zig toolchain before adopting it. Consume the generated archive, rather than treating the generator repository as a ready-to-import GTK module. Import `gtk4`, `gdk4`, `gio2`, `glib2`, and `gobject2` from the dependency. Link libc and system GTK4 via pkg-config. GTK 4.12 is the proposed minimum; confirm the spike runs against that baseline and avoid newer APIs unless the minimum is deliberately raised. No terminal rendering library or GTK layer-shell integration is needed. Prefer plain GTK4 for Pearl theme fidelity; libadwaita is not required.

Enable the GUI by default with a lazy binding dependency, plus `zig build run-gui`. Keep `zig build -Dgui=false` and `zig build test -Dgui=false` independent of GTK headers and downloads. Add separate `test-gui` model/backend checks and a GUI smoke target. Include GUI resources and desktop metadata in the package paths. Package `px2-gui` with a matching `px2`, application icon, desktop entry, and GTK runtime dependency by default; preserve CLI-only packaging through `PX2_BUILD_GUI=0`. The installer includes the GUI by default and supports `--no-gui`. No new privileged service is required.

## Architecture

```text
GTK widgets and actions
        │ immutable snapshots + staged edits
        ▼
GUI model / validation / serialized operation queue
        │ GIO asynchronous subprocesses, argv + JSON
        ▼
existing px2 CLI ── device.lock ── HID++ / profile writes
        │
        └── desired.json and watch-status.json ── px2 watch
```

Use [GtkApplication](https://docs.gtk.org/gtk4/class.Application.html) and `GtkApplicationWindow` for window and action lifecycle. Build the header, sidebar and editor with native Box, ListBox, Stack, ScrolledWindow, DropDown, SpinButton and Scale widgets; use native dialogs for initialization and unsaved edits. Production remains a native application; the HTML mockup is only a review artifact.

[Gio.Subprocess](https://docs.gtk.org/gio/class.Subprocess.html) supports asynchronous subprocess communication and argument arrays. Launch a configured/resolved `px2` executable directly, never through a shell. Bound captured output, parse JSON schema version 1 into owned data, preserve stderr for details, and handle nonzero exits, missing JSON and unsupported schemas. Keep GTK access on the main thread. Ignore outdated read results with generation IDs and disconnect callbacks safely when views close.

| Proposed files | Responsibility |
| --- | --- |
| `src/gui/main.zig`, `app.zig` | Startup, single instance, window, application actions and lifecycle |
| `src/gui/backend.zig`, `protocol.zig` | Async CLI adapter, bounded streams, typed JSON, operation results |
| `src/gui/model.zig` | Capabilities, selected/active slots, drafts, dirty fields, conflicts and pending operations |
| `src/gui/ui/*.zig` | Profile, sensitivity, HITS, restoration and diagnostics views |
| `src/gui/theme.zig`, `preferences.zig` | Scoped Pearl tokens, system theme mode and GUI-only preferences |
| `resources/gui/`, `packaging/px2-gui.desktop` | CSS, symbolic application icon and launcher |
| `tests/gui/` | JSON fixtures, fake CLI and native integration coverage |

Store GUI-only appearance and window preferences under `$XDG_CONFIG_HOME/px2/gui.json` with the usual home fallback. Device state remains in the existing XDG state directory and is never rewritten directly by the GUI. Propagate `--state-dir`, `--backup-dir`, and explicit connection choices consistently. A custom state directory's watcher status must not be confused with the default systemd service.

### Existing command mapping

Every device command below also receives `--json` and the relevant global options.

| UI action | CLI command |
| --- | --- |
| Refresh connected device | `px2 snapshot` |
| Read restoration state without HID traffic | `px2 watch status` |
| Activate selected slot | `px2 profile activate N` |
| Change DPI | `px2 set dpi VALUE --profile N` |
| Change rate | `px2 set rate HZ --profile N` |
| Apply changed left/right fields | `px2 set hits left --profile N --actuation VALUE` (and only other changed options) |
| Review / initialize factory slot | `px2 profile initialize N --from-factory --dry-run`, then explicit confirmation and the same command without `--dry-run` |
| Diagnostics | `px2 doctor` |

Initial snapshot, explicit Refresh and post-action reconciliation may query HID. Avoid periodic device snapshots that could prevent sleep. Monitor local state files, debounce changes, and read watcher status for ongoing restoration information. Use passive device arrival/removal notifications; cached readings carry a timestamp and disconnected label. Reconnecting never silently submits a retained draft.

Before applying, refresh the selected profile and relevant desired revision; if externally changed, offer reload or deliberate reapplication of the user's changed fields. The CLI's `device.lock` serializes each command with the watcher but does not make a sequence atomic or provide compare-and-swap. Pass `--profile N` to HITS so an intervening active-profile change is rejected. For the initial GUI, document last-writer behavior within a command; add an expected-revision contract later if strict conflict rejection is needed.

Do not force-kill an onboard write on a GUI timer or window close. Hold the application while writes finish, disable duplicate writes, and show a waiting state if the device lock is busy. Cancellation may stop queued work before launch; cancellable reads can discard their results. Never automatically retry a write with an uncertain result. The existing device timeout bounds individual HID requests, not the whole lock wait.

## Accuracy and failure states

- Label profile DPI/rate **Saved on mouse**. `snapshot.effective` is a compatibility alias for saved data and must not be shown as verified live state. Raw getter values belong in Diagnostics with a stale-reading explanation.
- Label successful onboard verification **Profile saved; readback passed**. Live application remains unverified. HITS readback success has its own narrower meaning.
- Treat absent/sleeping devices as waiting, retain drafts in memory, and disable Apply. Missing capabilities disable the affected control rather than inventing ranges.
- Distinguish missing CLI, access denied, factory-only, invalid CRC, unsupported layout, incompatible JSON, invalid desired state, external change, partial Apply, and write outcome unknown.
- The restoration page displays status and a copyable service setup command for the default state directory. Service enable/disable controls, profile import/export and backup browsing are follow-up work; initialization is the only destructive confirmation in the first editor.

## Delivery sequence and acceptance

1. **Binding and theme spike.** Pin and compile Ghostty bindings with Zig 0.16; open a native GTK window in Pearl dark/light and system mode. Verify the GTK baseline and Wayland/X11 startup. CLI-only builds must still work without GTK installed.
2. **Read-only editor.** Add typed JSON parsing, fake-backend fixtures, device/profile browsing, diagnostics and watcher status. Verify missing device/CLI, unsupported schema and capability failures. No GUI code writes device or desired-state files.
3. **Staged configuration.** Add dirty-field validation, sequential DPI/rate and per-button HITS writes, activation, conflict checks, partial-result handling, and readback reconciliation. Verify inactive edits do not activate profiles, sliders do not issue commands, and nullable HITS fields are preserved.
4. **Initialization and restoration polish.** Add the dry-run review and factory confirmation, backup-result display, file monitoring, reconnect handling and close-during-write behavior. Verify corrupt profiles remain blocked and stopping the GUI leaves restoration running.
5. **Packaging and release checks.** Add the desktop entry/icon and GUI packaging; run the existing Zig tests and watcher smoke tests, fake-CLI integration checks and native keyboard/accessibility smoke checks. Compare native screenshots to the approved review design at normal/narrow sizes, both palettes and 200% text scale.

Hardware acceptance uses a consenting development mouse: test direct USB and receiver, each supported rate, DPI limits, independent left/right HITS, active and inactive edits, a factory slot, disconnect during a write, wake and suspend/resume. Verify backup contents, preserved unknown bytes and CRCs. Confirm actual pointer/HITS behavior instead of trusting stale getters, and confirm opening the GUI does not stop the mouse sleeping.

## Design review

The mockup demonstrates dark/light appearance, selecting an inactive or factory slot, staged sensitivity and HITS edits, discard confirmation, activation, initialization, restoration and diagnostics. Review the sidebar/editor balance, the explicit Apply footer, the separate activation action and the distinction between saved and reported data. All fixture values reset on reload. See [mockup instructions and verification](mockups/README.md).
