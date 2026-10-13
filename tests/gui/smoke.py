#!/usr/bin/env python3
"""Runs native GTK against a stateful fake CLI; requires a GTK display backend."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT/'zig-out/bin/px2-gui'
FAKE = ROOT/'tests/gui/fake_px2.py'
cases = ['basic','partial','conflict','slow','offline','permission','badschema','malformed','oversized','missing','invalidstate']
for case in cases:
    with tempfile.TemporaryDirectory(prefix='px2 gui test ') as directory:
        root=Path(directory)
        env=dict(os.environ, PX2_GUI_FAKE_DIR=directory, PX2_GUI_SCENARIO=case, XDG_CONFIG_HOME=directory, GTK_A11Y='none')
        mode = 'readonly' if case in ['offline','permission','badschema','malformed','oversized','missing'] else case
        cli = str(root/'missing-px2') if case == 'missing' else str(FAKE)
        result=subprocess.run([str(BINARY),'--cli',cli,'--state-dir',directory,'--backup-dir',str(root/'backups with spaces'),'--smoke-test',mode],env=env,capture_output=True,text=True,timeout=45)
        assert result.returncode == 0, (case,result.stdout,result.stderr)
        assert 'CRITICAL' not in result.stderr and 'Gtk-WARNING' not in result.stderr, (case,result.stderr)
        commands=[json.loads(line) for line in (root/'commands.jsonl').read_text().splitlines()] if (root/'commands.jsonl').exists() else []
        writes=[c for c in commands if 'set' in c or ('profile' in c and '--dry-run' not in c)]
        if case in ['conflict','offline','permission','badschema','malformed','oversized','missing','invalidstate']:
            assert not writes, (case,writes)
        if case == 'partial':
            assert len(writes)==2 and 'dpi' in writes[0] and 'rate' in writes[1], writes
        if case == 'basic':
            hits=[c for c in writes if 'hits' in c]
            assert len(hits)==1 and '--haptics' in hits[0] and '--actuation' not in hits[0] and '--rapid' not in hits[0],hits
            assert '--profile' in hits[0] and 'left' in hits[0]
            initializations=[c for c in commands if 'initialize' in c]
            assert len(initializations)==2 and '--dry-run' in initializations[0] and '--dry-run' not in initializations[1]
        for c in commands:
            assert c[c.index('--state-dir')+1]==directory
            assert c[c.index('--backup-dir')+1]==str(root/'backups with spaces')
        assert not (root/'desired.json').exists(), 'GUI must not write backend state'
        print(f'{case}: native GUI and argv checks passed')
