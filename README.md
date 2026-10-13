# px2

`px2` is an unofficial Linux CLI for the Logitech PRO X2 SUPERSTRIKE, written
for Zig 0.16. It speaks HID++ 2.0 directly over `hidraw` and supports both the
USB cable and the LIGHTSPEED receiver.

## Install directly from this checkout

With Zig 0.16, GTK 4.12+ development files and pkg-config installed, run this
as your normal desktop user:

```sh
./packaging/install.sh 1
```

Replace `1` with your desired profile, or omit it to keep your saved selection.
The script builds and tests the code, uses sudo to install `/usr/local/bin/px2`,
`/usr/local/bin/px2-gui`, the desktop launcher and the udev rules, then installs
and enables the watcher as a user service. Pass `--no-gui` for a CLI-only install.
Wake the mouse before running it. If activation fails, installation still
finishes and the script prints the command to retry after reconnecting.
Rerun the script to install subsequent changes. It does not initialize or
rewrite onboard profile sectors.

## Native GTK configuration editor

The default build includes the Pearl-style editor with Ghostty GObject bindings:

```sh
zig build
./zig-out/bin/px2-gui
```

Requires Zig 0.16, GTK 4.12+ development files and pkg-config. The editor uses
`px2` for device operations and provides profile, DPI, polling-rate, HITS,
restoration and diagnostic views. See the [GUI guide](docs/GUI.md) for behavior,
installation and testing, [native screenshots](docs/native/README.md), and the [design plan](docs/GUI_PLAN.md) and
[interactive mockup](docs/mockups/index.html) for the original review artifacts.

## Build

```sh
zig build
zig build test
python3 tests/watch_smoke.py
./zig-out/bin/px2 help
```

For a CLI-only build without GTK or binding downloads, use `zig build -Dgui=false`
and `zig build test -Dgui=false`.

## Permissions

Install `packaging/70-logitech-superstrike.rules` in `/etc/udev/rules.d/`,
reload udev, and reconnect the cable/receiver. Review the rule before installing
it; it grants the logged-in desktop user access only to the two known USB PIDs.

## Arch Linux and derivatives

Build and install a pacman package from the repository checkout with Shelly:

```sh
cd packaging/arch
shelly build --check PKGBUILD
shelly install standard "$(makepkg --packagelist)"
```

Alternatively, use `makepkg` directly:

```sh
cd packaging/arch
makepkg -si
```

The package includes `/usr/bin/px2-gui`, its desktop launcher and icon by default.
Set `PX2_BUILD_GUI=0` when invoking Shelly or makepkg for a CLI-only package.
This also installs `/usr/bin/px2`, the udev rule under `/usr/lib/udev/rules.d`,
`px2-watch.service` under `/usr/lib/systemd/user`, optional Noctalia files,
and the README under `/usr/share/doc/prox2-superstrike`. Reconnect the mouse
after the first installation so logind applies the device ACL.

## Automatic restoration with Pearl or other desktops

Select your profile once, then enable the desktop-independent user service:

```sh
px2 profile activate 1
systemctl --user daemon-reload
systemctl --user enable --now px2-watch.service
px2 watch status
```

An editable profile must first be initialized if it is still factory-only
(see below). Successful profile activation, active-profile DPI/rate changes,
and HITS changes save intent in `$XDG_STATE_HOME/px2/desired.json`, falling back
to `~/.local/state/px2/desired.json`. Only explicitly set HITS fields are saved,
separately for each profile and button. Activate a profile before configuring
its HITS settings. Dry runs never update desired settings. Editing an inactive
profile does not change the selected profile.

`px2 watch` restores on startup, resume, reconnection notifications, and the
first mouse report after at least 30 seconds without input. This last trigger
is a fallback for firmware that does not announce wake. It monitors all matching
hidraw interfaces passively; its periodic checks read local state and sysfs,
without sending idle status requests. Recovery reads the selected profile and
applies live DPI, rate, and saved HITS values, without writing onboard sectors
or making backups. Five failed attempts use increasing delays, then wait for a
new wake, reconnect, or settings change. An absent mouse is a normal waiting
state. With no saved selection, the service waits for `profile activate`.

The watcher and CLI serialize device operations using advisory locks and reload
intent under the lock before recovery. These locks coordinate `px2` processes;
other mouse-management applications do not participate. State is intended for
one SUPERSTRIKE per user. `auto` supports switching between cable and receiver;
an explicit `--connection direct|receiver` saved by a successful setting change
restricts subsequent recovery to that connection. Use `--connection auto` on
your next activation to clear that restriction.

For a source build, run the watcher in the foreground:

```sh
./zig-out/bin/px2 watch
./zig-out/bin/px2 watch status --json
```

Use `--state-dir PATH` consistently on both the watcher and CLI to isolate
another configuration. `watch status` works while the mouse is absent and
reports whether the process is running, desired settings, the last recorded
phase, last successful restore time, and errors. A stopped process can leave a
historical status record; the separate `running` field is authoritative for
process presence. `restoration_verified: false` means live DPI/rate are not
independently verified: the firmware's getters can be stale.

```sh
journalctl --user -u px2-watch.service -f
systemctl --user disable --now px2-watch.service
```

## Wake diagnostics and hardware validation

Stop the service before running a diagnostic watcher; duplicate watchers using
the same state directory are rejected:

```sh
systemctl --user stop px2-watch.service
px2 snapshot --json > /tmp/px2-before-idle.json
px2 profile export 1 /tmp/px2-before-idle.bin
px2 watch --trace --idle-seconds 30
```

Leave the mouse untouched until it sleeps, then move it. The trace logs HID++
notifications and recovery transitions. It continues to restore configured
settings. After stopping the foreground watcher with Ctrl-C, capture a second
snapshot and export, compare the profile bytes with `cmp`, and restart the
service. Check actual pointer movement and HITS behavior as well as the logs;
getter values alone cannot establish that the firmware applied DPI/rate.
Repeat for suspend/resume, receiver unplug/replug, mouse power cycling,
cable/receiver switching, a profile change while recovery is pending, and a
service restart. Confirm that the mouse still sleeps normally. If sleep occurs
in less than 30 seconds, lower `--idle-seconds` below that interval.

Unit tests simulate reports, retries, stale getters, corrupted profiles and
state, and reject onboard writes during recovery. The hardware wake packet
sequence and idle battery behavior still need validation on the actual device.
The notification decoder follows the connection flags used by
[Solaar](https://github.com/pwr-Solaar/Solaar/blob/master/lib/logitech_receiver/notifications.py);
passive report reads use the kernel's
[hidraw interface](https://docs.kernel.org/hid/hidraw.html).

## Optional Noctalia integration

The watcher runs independently of the Noctalia plugin. To install the plugin
in Noctalia's per-user data directory:

```sh
px2-noctalia-install install
```

Enable the plugin and add its widget from Noctalia Settings, or enable it from
the command line:

```sh
noctalia msg plugins enable prox2-superstrike/prox2-superstrike
```

Left-click the bar widget to open the control panel, or open it directly with
`noctalia msg panel-toggle prox2-superstrike/prox2-superstrike:control`.

## Examples

```sh
px2 list
px2 status --connection receiver
px2 snapshot --json
px2 get hits
px2 set hits both --actuation 3 --rapid 2 --haptics 4 --dry-run
px2 set dpi 1600 --profile 1 --dry-run
px2 profile inspect --json
px2 profile initialize 5 --from-factory --dry-run
px2 profile export 1 profile-1.bin
px2 doctor --json
```

Factory profiles live in a read-only ROM bank. A factory-only profile is shown
with its saved DPI and rate, but must be initialized before it can be edited:

```sh
px2 profile initialize 1 --from-factory --dry-run
px2 profile initialize 1 --from-factory
```

Initialization clones the decodable factory template into the selected RAM
slot, constructs a CRC-validated RAM control table if needed, and verifies the
committed bytes. Backups are saved under
`$XDG_STATE_HOME/px2/backups` (or `~/.local/state/px2/backups`); override this
with `--backup-dir PATH`. Regular profile writes preserve unknown bytes, update
the CRC, commit, and verify the entire sector. Reported live DPI and polling
rate values may be stale on this firmware; `px2 get dpi` and `px2 get rate`
read the persistent onboard profile image instead. For the live controls, the
CLI follows [Solaar's HID++ sequence](https://github.com/pwr-Solaar/Solaar): disable onboard profiles, then mirror the
saved values through Extended Adjustable DPI (`0x2202`) and Extended Adjustable
Report Rate (`0x8061`). `snapshot.saved` contains saved profile values;
`snapshot.reported` preserves the raw, commonly stale HID++ getter values.
The compatibility field `snapshot.effective` also contains saved values and is
explicitly marked `source: "saved_profile", verified: false`. These values do
not prove that live settings survived sleep.

The Superstrike's format-8 profile is device-specific: its live sensor X/Y
pair occupies the final two words of the legacy five-word DPI area (bytes
9–12), and the resolution-index byte does not select that pair. `set dpi`
patches only those four bytes and the profile CRC, preserving every unknown
field.

`px2 rate measure` reads the mouse's associated evdev motion node rather than
the HID++ configuration node. Linux only emits evdev frames containing changed
state, so the result is a movement-dependent lower bound, not a definitive USB
polling-rate measurement.

This project is not affiliated with or endorsed by Logitech. Onboard-memory
writes carry hardware risk; keep the generated backup files.
