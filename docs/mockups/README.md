# PX2 GUI review mockup

Open [index.html](index.html) in a browser. This offline, interactive design study previews a proposed native Zig/GTK4 application using Pearl's base Material palette. It runs entirely on fictional data; it does not invoke PX2, contact the mouse, access state files, or change services.

The [implementation plan](../GUI_PLAN.md) defines the native architecture, backend mapping, packaging, failure handling and acceptance checks.

## Review images

| View | Screenshot |
| --- | --- |
| Sensitivity in Pearl dark | [Dark](px2-dark.png) |
| Sensitivity in Pearl light | [Light](px2-light.png) |
| Independent button settings | [HITS](px2-hits.png) |
| Factory-only profile | [Factory profile](px2-factory.png) |
| Cached settings while disconnected | [Disconnected](px2-disconnected.png) |
| Narrow window at 390 px | [Narrow](px2-narrow.png) |

## Interactions

- Change DPI or polling rate, then Apply or Discard. Invalid DPI blocks Apply. Sliders only change the draft.
- Switch profiles with pending edits to review the discard dialog. Cancel retains the editor and its values.
- Select profile 2 to inspect an inactive profile. Activate it explicitly to enable HITS. Left and right button edits remain independent.
- Select profile 5 or the Factory profile scenario to review initialization. Confirming creates a writable fixture copy.
- Open Restoration or Diagnostics. Their values demonstrate the distinction between saved state, reported values and process presence.
- Use the preview selector for disconnected, denied-access and partial-failure states. To exercise partial Apply, change both DPI and rate; the fixture saves DPI but leaves the failed rate edit pending.
- Switch dark/light appearance. Below 620 px a compact profile selector replaces the sidebar list. Inputs, buttons and dialogs work with the keyboard; Escape dismisses a dialog.

The review heading, scenario selector, appearance toggle and footer annotation sit outside the proposed application. Window decorations are illustrative. All mutations reset on reload. The fixture has five profiles, a 50-DPI step, seven polling rates and illustrative HITS limits; the native app must discover these from PX2 capabilities. The mouse silhouette is original inline SVG.

URL options: `?theme=light`, `?page=hits`, `?page=restoration`, `?page=diagnostics`, and `?state=offline|factory|permission|partial`. Combine options with `&`; a state scenario opens the sensitivity editor.

## Visual provenance

Colors, 12 px cards and spacing follow the local Pearl checkout at `d4ea6c3`, particularly `src/theme/theme.zig` and the Dome application styling. Browser fonts use installed Inter or Noto Sans with a sans-serif fallback. The proposed native implementation inherits GTK font and text scaling. Browser CSS is a review artifact, not a production GTK stylesheet. System GTK appearance and automatic Pearl custom-theme synchronization are not simulated.

## Verification

With Python Playwright and `/usr/bin/chromium` installed, regenerate screenshots and [verification.json](verification.json) from the repository root:

```sh
python3 docs/mockups/verify.py
```

The script checks staged edits, invalid inputs, discard/cancel, independent HITS, active-profile gating, initialization confirmation, disconnected state, partial failure, keyboard focus and horizontal overflow across four widths and two appearances. HTTP/HTTPS requests are blocked and recorded. This verifies the HTML prototype only; native GTK rendering, assistive technology, text scaling and physical device behavior remain implementation acceptance work.
