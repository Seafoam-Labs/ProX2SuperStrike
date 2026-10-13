#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./packaging/install.sh [--no-gui | --gui] [PROFILE]

Build and test px2 and its GTK4 editor, install them in /usr/local/bin,
install the udev rules, and enable the watcher for the current user.
Requires Zig 0.16, systemd, GTK4 development files and pkg-config.

Pass a profile number (1-5) to activate it after installation. Omit it to
keep your saved selection. Run as your normal desktop user; the script
uses sudo only for the binary and udev setup.
Pass --no-gui for a CLI-only installation without GTK4 or pkg-config.
The --gui flag is also accepted for compatibility.
EOF
}

fail() {
  printf 'Install failed: %s\n' "$*" >&2
  exit 1
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  usage
  exit 0
fi
gui=true
profile=
for arg in "$@"; do
  if [[ $arg == --gui ]]; then
    gui=true
  elif [[ $arg == --no-gui ]]; then
    gui=false
  elif [[ -z $profile ]]; then
    profile=$arg
  else
    usage >&2; exit 2
  fi
done
if [[ -n $profile && ! $profile =~ ^[1-5]$ ]]; then
  fail 'The optional profile number must be between 1 and 5.'
fi
if (( EUID == 0 )); then
  fail 'Run this script without sudo from your desktop session.'
fi

for tool in zig systemctl udevadm sudo install sed mktemp; do
  command -v "$tool" >/dev/null || fail "Missing $tool. Install it and rerun. Zig 0.16 is required (Arch: sudo pacman -S --needed zig)."
done
zig_version=$(zig version)
[[ $zig_version == 0.16.* ]] || fail "Found Zig $zig_version; this project requires Zig 0.16."
if [[ $gui == true ]]; then
  command -v pkg-config >/dev/null || fail 'The GUI requires pkg-config.'
  pkg-config --atleast-version=4.12 gtk4 || fail 'The GUI requires GTK 4.12 or newer development files.'
fi
systemctl --user show-environment >/dev/null || fail 'The systemd user manager is unavailable. Run this in your logged-in desktop session.'

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
unit_dir=${XDG_CONFIG_HOME:-"$HOME/.config"}/systemd/user
state_dir=${XDG_STATE_HOME:-"$HOME/.local/state"}/px2
[[ $state_dir == /* && $unit_dir == /* ]] || fail 'XDG_STATE_HOME and XDG_CONFIG_HOME must be absolute paths.'
[[ $state_dir != *$'\n'* && $state_dir != *$'\r'* ]] || fail 'The state directory cannot contain a newline.'
cd -- "$project_dir"

printf 'Building px2 with Zig %s...\n' "$zig_version"
zig build -Doptimize=ReleaseSafe -Dgui="$gui"
zig build test -Dgui="$gui"
if [[ $gui == true ]]; then zig build test-gui; fi

# Quote the explicit state path for systemd, including its $ and % expansion.
# This keeps the service and CLI on the same state even when the user manager
# has a different XDG_STATE_HOME from the invoking shell.
state_arg=${state_dir//\\/\\\\}
state_arg=${state_arg//\"/\\\"}
state_arg=${state_arg//\$/\$\$}
state_arg=${state_arg//%/%%}
staging_dir=$(mktemp -d)
trap 'rm -rf -- "$staging_dir"' EXIT
while IFS= read -r line; do
  if [[ $line == ExecStart=* ]]; then
    printf 'ExecStart=/usr/local/bin/px2 watch --state-dir "%s"\n' "$state_arg"
  else
    printf '%s\n' "$line"
  fi
done < packaging/px2-watch.service > "$staging_dir/px2-watch.service"

printf 'Installing binary and mouse access rules (sudo may ask for your password)...\n'
sudo install -Dm755 zig-out/bin/px2 /usr/local/bin/px2
if [[ $gui == true ]]; then
  sudo install -Dm755 zig-out/bin/px2-gui /usr/local/bin/px2-gui
  sudo install -Dm644 packaging/px2-gui.desktop /usr/local/share/applications/io.github.px2.Configurator.desktop
  sudo install -Dm644 resources/gui/px2.svg /usr/local/share/icons/hicolor/scalable/apps/io.github.px2.Configurator.svg
fi
sudo install -Dm644 packaging/70-logitech-superstrike.rules /etc/udev/rules.d/70-logitech-superstrike.rules
sudo udevadm control --reload-rules
# Reevaluate access rules for existing hidraw devices without disconnecting USB.
sudo udevadm trigger --action=change --subsystem-match=hidraw
sudo udevadm settle

install -Dm644 "$staging_dir/px2-watch.service" "$unit_dir/px2-watch.service"
systemctl --user daemon-reload

activation_failed=false
if [[ -n $profile ]]; then
  if ! /usr/local/bin/px2 --state-dir "$state_dir" profile activate "$profile"; then
    activation_failed=true
    printf '\nProfile activation failed. Wake or reconnect the mouse, then retry:\n' >&2
    printf '  /usr/local/bin/px2 --state-dir %q profile activate %s\n' "$state_dir" "$profile" >&2
  fi
fi

systemctl --user enable px2-watch.service
systemctl --user restart px2-watch.service
systemctl --user is-active --quiet px2-watch.service || fail 'Watcher did not start. Check journalctl --user -u px2-watch.service.'
/usr/local/bin/px2 --state-dir "$state_dir" watch status

printf '\nInstalled /usr/local/bin/px2 and enabled px2-watch.service.\n'
printf 'Logs: journalctl --user -u px2-watch.service -f\n'
if [[ -z $profile && ! -f $state_dir/desired.json ]]; then
  printf 'Select your profile once (replace N with its number):\n'
  printf '  /usr/local/bin/px2 --state-dir %q profile activate N\n' "$state_dir"
fi
if [[ $(command -v px2 || true) != /usr/local/bin/px2 ]]; then
  printf 'Use /usr/local/bin/px2, or put /usr/local/bin first in your PATH.\n'
fi
if [[ $activation_failed == true ]]; then
  printf 'Installation completed, but the requested profile still needs activation.\n' >&2
  exit 1
fi
