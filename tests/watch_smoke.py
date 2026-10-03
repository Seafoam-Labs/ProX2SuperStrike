#!/usr/bin/env python3
"""Exercise watcher lifecycle without opening or configuring any real mouse.

Run after `zig build`: python3 tests/watch_smoke.py
"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


BINARY = Path(__file__).resolve().parents[1] / "zig-out/bin/px2"


def main():
    with tempfile.TemporaryDirectory(prefix="px2-watch-test-") as directory:
        root = Path(directory)
        common = [str(BINARY), "--state-dir", directory]

        def command(*args):
            return subprocess.run(common + list(args), capture_output=True, text=True)

        def status():
            result = command("watch", "status", "--json")
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)

        def wait_for(predicate):
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                value = status()
                if predicate(value):
                    return value
                time.sleep(0.1)
            raise AssertionError(status())

        def save_state(value):
            temporary = root / "new-state.json"
            temporary.write_text(json.dumps(value))
            os.replace(temporary, root / "desired.json")

        assert status()["running"] is False
        log = (root / "watch.log").open("w+")
        # The explicit nonexistent path excludes every real device from scanning.
        process = subprocess.Popen(
            common + ["watch", "--device", "/dev/px2-smoke-test-no-such-device"],
            stdout=subprocess.DEVNULL,
            stderr=log,
        )
        try:
            wait_for(lambda s: s["running"] and s["last_status"] is not None)
            duplicate = command("watch")
            assert duplicate.returncode != 0 and "AlreadyRunning" in duplicate.stderr
            assert not (root / "desired.json").exists()

            save_state({"sector": 3, "revision": 1})
            waiting = wait_for(lambda s: s["last_status"]["phase"] == "waiting_for_device")
            assert waiting["last_status"]["desired_profile"] == 3
            assert waiting["last_status"]["last_restore_ms"] is None

            save_state({"sector": 4, "revision": 2})
            wait_for(lambda s: s["last_status"]["desired_profile"] == 4)

            # No hardware operation succeeds; neither failure nor dry-run may
            # replace the selected profile with a default inferred from a device.
            before = (root / "desired.json").read_bytes()
            result = command("profile", "activate", "2", "--dry-run", "--device", "/dev/px2-smoke-test-no-such-device")
            assert result.returncode != 0
            assert (root / "desired.json").read_bytes() == before

            (root / "desired.json").write_text("{broken")
            wait_for(lambda s: s["last_status"]["phase"] == "invalid_state")
            assert (root / "desired.json").read_text() == "{broken"

            save_state({"sector": 5, "revision": 3})
            wait_for(lambda s: s["last_status"]["desired_profile"] == 5 and s["last_status"]["phase"] == "waiting_for_device")
            assert process.poll() is None
        finally:
            process.terminate()
            process.wait(timeout=5)
            log.close()
        assert status()["running"] is False
        assert status()["desired"]["sector"] == 5
        assert not (root / "backups").exists()
    print("watch lifecycle smoke checks passed")


if __name__ == "__main__":
    main()
