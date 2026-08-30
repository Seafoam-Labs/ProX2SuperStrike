# px2

`px2` is an unofficial Linux CLI for the Logitech PRO X2 SUPERSTRIKE, written
for Zig 0.16. It speaks HID++ 2.0 directly over `hidraw` and supports both the
USB cable and the LIGHTSPEED receiver.

## Build

```sh
zig build
zig build test
./zig-out/bin/px2 help
```

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

This installs `/usr/bin/px2`, the udev rule under `/usr/lib/udev/rules.d`, and
the README under `/usr/share/doc/prox2-superstrike`. Reconnect the mouse after
the first installation so logind applies the new device ACL.

## Examples

```sh
px2 list
px2 status --connection receiver
px2 get hits
px2 set hits both --actuation 3 --rapid 2 --haptics 4 --dry-run
px2 set dpi 1600 --profile 1 --dry-run
px2 profile export 1 profile-1.bin
px2 doctor --json
```

Profile writes are restricted to the known 255-byte format. The CLI validates
the original CRC, preserves unknown bytes, saves `px2-profile-N.backup.bin`,
updates the CRC, commits, and verifies the entire sector. Reported live DPI and
polling-rate values may be stale on this firmware; `px2 get dpi` and
`px2 get rate` read the persistent onboard profile instead.

This project is not affiliated with or endorsed by Logitech. Onboard-memory
writes carry hardware risk; keep the generated backup files.
