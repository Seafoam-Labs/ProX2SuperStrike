#!/usr/bin/env python3
"""Stateful fake CLI for native GUI tests. Never opens HID or calls real px2."""
import json
import os
from pathlib import Path
import sys
import time

root = Path(os.environ['PX2_GUI_FAKE_DIR'])
scenario = os.environ.get('PX2_GUI_SCENARIO', 'basic')
args = sys.argv[1:]
with (root / 'commands.jsonl').open('a') as f:
    f.write(json.dumps(args) + '\n')
# Strip global arguments; values remain single argv elements even with spaces.
words = []
i = 0
while i < len(args):
    if args[i] == '--json':
        i += 1
    elif args[i] in ('--state-dir', '--backup-dir', '--connection', '--device'):
        i += 2
    else:
        words.append(args[i]); i += 1
path = root / 'fixture.json'
if path.exists():
    state = json.loads(path.read_text())
else:
    state = {'active': 1, 'revision': 1, 'snapshots': 0,
             'profiles': [{'slot': n, 'initialized': n != 5, 'editable': n != 5,
                           'editable_reason': None if n != 5 else 'factory_only',
                           'crc_valid': True, 'rom_health': 'valid', 'dpi_x': 1600,
                           'dpi_y': 1600, 'rate_hz': 1000} for n in range(1, 6)],
             'hits': [{'actuation': 3, 'rapid_trigger': 2, 'haptics': 4} for _ in range(2)]}

def emit(value, code=0):
    path.write_text(json.dumps(state))
    print(json.dumps(value), flush=True)
    sys.exit(code)

def fail(error):
    emit({'schema_version': 1, 'ok': False, 'error': error}, 1)

if words == ['watch', 'status']:
    emit({'schema_version': 1, 'running': scenario != 'stopped', 'state_directory': str(root),
          'state_error': 'SyntaxError' if scenario == 'invalidstate' else None,
          'desired': {'revision': state['revision'], 'sector': state['active'], 'connection': 'auto'},
          'last_status': {'phase': 'monitoring', 'last_restore_ms': 1791913320000,
                          'last_error': None, 'restoration_verified': False}})
if words == ['snapshot']:
    if scenario in ('offline', 'permission'):
        fail('NoDevice' if scenario == 'offline' else 'AccessDenied')
    if scenario == 'oversized':
        print('x' * (1024 * 1024 + 80000)); sys.exit(0)
    if scenario == 'malformed':
        print('{invalid'); sys.exit(0)
    state['snapshots'] += 1
    if scenario == 'conflict' and state['snapshots'] == 2:
        state['profiles'][0]['dpi_x'] = 800
        state['profiles'][0]['dpi_y'] = 800
        state['revision'] += 1
    p = state['profiles'][state['active'] - 1]
    emit({'schema_version': 2 if scenario == 'badschema' else 1,
          'device': {'name': 'PRO X2 SUPERSTRIKE', 'connection': 'receiver', 'path': '/dev/fake-px2'},
          'battery': {'percent': 78, 'charging': False}, 'active_profile': state['active'],
          'desired_profile': state['active'], 'saved': {k:p[k] for k in ('dpi_x','dpi_y','rate_hz')},
          'reported': {'dpi_x': 800, 'dpi_y': 800, 'rate_hz': 1000},
          'supported': {'dpi': {'min': 100, 'max': 44000, 'step': 50}, 'rates_hz':[125,250,500,1000,2000,4000,8000]},
          'hits': {'capabilities': {'button_count':2,'max_actuation':10,'max_rapid_trigger':5,'max_haptics':5},
                   'left':state['hits'][0],'right':state['hits'][1]}, 'profiles':state['profiles']})
if words == ['doctor']:
    emit({'selected': {'path':'/dev/fake-px2'},'device_index':1,'candidates':[],'features':[8706,32865]})
if words[:2] == ['profile', 'initialize']:
    slot = int(words[2])
    if '--dry-run' in words:
        emit({'schema_version':1,'ok':True,'dry_run':True,'profile':slot,'would_initialize_control':False})
    p = state['profiles'][slot-1]; p.update(initialized=True,editable=True,editable_reason=None)
    emit({'schema_version':1,'ok':True,'backup_dir':str(root/'backups'/'initialize')})
if words[:2] == ['profile', 'activate']:
    state['active'] = int(words[2]); state['revision'] += 1
    emit({'schema_version':1,'ok':True})
if words[0] == 'set':
    slot = int(words[words.index('--profile')+1]); p=state['profiles'][slot-1]
    if scenario == 'slow': time.sleep(1)
    if scenario == 'partial' and words[1] == 'rate': fail('WriteVerificationFailed')
    if words[1] == 'dpi': p['dpi_x'] = p['dpi_y'] = int(words[2])
    elif words[1] == 'rate': p['rate_hz'] = int(words[2])
    elif words[1] == 'hits':
        if slot != state['active']: fail('ProfileNotActive')
        button = 0 if words[2] == 'left' else 1
        for flag,key in [('--actuation','actuation'),('--rapid','rapid_trigger'),('--haptics','haptics')]:
            if flag in words: state['hits'][button][key] = int(words[words.index(flag)+1])
    else: fail('InvalidSubcommand')
    state['revision'] += 1
    emit({'schema_version':1,'ok':True,'backup':{'path':str(root/'backup.bin'),'created':True}})
fail('InvalidCommand')
