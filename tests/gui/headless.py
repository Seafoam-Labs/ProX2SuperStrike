#!/usr/bin/env python3
"""Run the GTK smoke suite on an isolated Broadway display, without a desktop."""
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

with tempfile.TemporaryDirectory(prefix='px2-gtk-display-') as runtime:
    os.chmod(runtime, 0o700)
    with socket.socket() as probe:
        probe.bind(('127.0.0.1',0)); port=probe.getsockname()[1]
    env=dict(os.environ, XDG_RUNTIME_DIR=runtime, GDK_BACKEND='broadway', BROADWAY_DISPLAY=':17', GSK_RENDERER='broadway', GTK_A11Y='none')
    server=subprocess.Popen(['gtk4-broadwayd','--address=127.0.0.1',f'--port={port}',':17'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    try:
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.1): break
            except OSError: time.sleep(.05)
        else: raise RuntimeError('Broadway did not start')
        result=subprocess.run([sys.executable,str(Path(__file__).with_name('smoke.py'))]+sys.argv[1:],env=env)
        sys.exit(result.returncode)
    finally:
        server.terminate(); server.wait(timeout=5)
