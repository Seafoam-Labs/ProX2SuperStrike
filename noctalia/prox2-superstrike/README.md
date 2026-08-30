# PRO X2 SUPERSTRIKE

Noctalia v5 bar widget and control panel for the Logitech PRO X2 SUPERSTRIKE.
It delegates all hardware access to the installed `px2` CLI.

## Plugin

| Field | Value |
| --- | --- |
| Plugin ID | `prox2-superstrike/prox2-superstrike` |
| Bar widget | `mouse` |
| Panel | `control` |
| Service | `service` |

## Usage

Enable `prox2-superstrike/prox2-superstrike` in **Settings → Plugins**, then add the
**PRO X2 SUPERSTRIKE** widget to a bar. Left-click the widget to open the panel;
right-click it to request an immediate refresh.

The panel can select the direct USB or LIGHTSPEED connection, inspect battery
and profile state, activate profiles, and apply DPI, polling-rate, and HITS
settings supported by `px2`.

The panel can also be opened from a terminal:

```sh
noctalia msg panel-toggle prox2-superstrike/prox2-superstrike:control
```

## Requirements

- `px2`
- Noctalia v5 with plugin API 24 or newer

Persistent profile writes retain the CLI's CRC validation, backup, commit, and
read-back verification. The plugin never invokes a shell: dynamic arguments are
passed to `px2` with Noctalia's argv-array process API.
