# Native PX2 GTK previews

These images are captured from the implemented Zig/GTK4 application with fictional data from the test CLI. They are native widget renders, not the HTML mockup.

- [Pearl dark](dark.png)
- [Pearl light](light.png)
- [Buttons and HITS](hits.png)
- [Restoration](restoration.png)
- [Narrow window](narrow.png)
- [System GTK appearance](system.png)

Regenerate after building with `zig build -Dgui=true`:

```sh
python3 tests/gui/capture.py
```

Capture requires GTK's `gtk4-broadwayd`, Python Playwright and system Chromium. It uses a private display bound to localhost, Broadway's own renderer, and temporary fixture directories. It never invokes the real mouse backend. Window content scrolls independently, so images can show only the visible portion of the editor.
