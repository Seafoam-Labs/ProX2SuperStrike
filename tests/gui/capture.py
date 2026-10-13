#!/usr/bin/env python3
"""Capture actual GTK widgets on a private Broadway display using fixture data."""
import os
from pathlib import Path
import socket
import shutil
import subprocess
import tempfile
import time
from playwright.sync_api import sync_playwright

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'docs/native'
OUT.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='px2-capture-') as temporary:
    runtime=Path(temporary)/'runtime';runtime.mkdir(mode=0o700)
    with socket.socket() as s:
        s.bind(('127.0.0.1',0));port=s.getsockname()[1]
    env=dict(os.environ,XDG_RUNTIME_DIR=str(runtime),GDK_BACKEND='broadway',BROADWAY_DISPLAY=':18',GSK_RENDERER='broadway',GTK_A11Y='none')
    server=subprocess.Popen(['gtk4-broadwayd','--address=127.0.0.1',f'--port={port}',':18'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    try:
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.1):break
            except OSError:time.sleep(.05)
        playwright = sync_playwright().start()
        browser = playwright.chromium.launch(executable_path='/usr/bin/chromium', headless=True, args=['--no-sandbox'])
        page = browser.new_page(viewport={'width':1400,'height':1100})
        page.goto(f'http://127.0.0.1:{port}')
        page.wait_for_timeout(300)
        cases=[('dark','dark',1120,'capture'),('light','light',1120,'capture'),('hits','dark',1120,'capture-hits'),('restoration','dark',1120,'capture-restoration'),('narrow','dark',390,'capture'),('system','system',1120,'capture')]
        for name,appearance,width,mode in cases:
            if os.environ.get('PX2_CAPTURE_VIEW') and os.environ['PX2_CAPTURE_VIEW'] != name:
                continue
            folder=Path(temporary)/name;folder.mkdir()
            e=dict(env,PX2_GUI_FAKE_DIR=str(folder),XDG_CONFIG_HOME=str(folder))
            process=subprocess.Popen([str(ROOT/'zig-out/bin/px2-gui'),'--cli',str(ROOT/'tests/gui/fake_px2.py'),'--state-dir',str(folder),'--appearance',appearance,'--width',str(width),'--smoke-test',mode],env=e,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            started=time.monotonic()
            while process.poll() is None and time.monotonic()-started<20:
                page.wait_for_timeout(50)
            stdout,stderr=process.communicate(timeout=5)
            result=subprocess.CompletedProcess(process.args,process.returncode,stdout,stderr)
            assert result.returncode==0,(name,result.stderr)
            assert 'CRITICAL' not in result.stderr and 'Gtk-WARNING' not in result.stderr,(name,result.stderr)
            shutil.copyfile(folder/'native.png',OUT/f'{name}.png')
            print(f'{name}: captured native GTK widgets')
    finally:
        if "browser" in locals(): browser.close()
        if "playwright" in locals(): playwright.stop()
        server.terminate();server.wait(timeout=5)
