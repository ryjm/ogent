#!/usr/bin/env python3
"""Record review commands without rewriting production files."""
import json
from pathlib import Path
import subprocess
import sys
import time

target = Path(__file__).resolve().parent
name, *command = sys.argv[1:]
started = time.time()
result = subprocess.run(command, cwd='/workspace/ogent', capture_output=True)
(target / (name + '.stdout')).write_bytes(result.stdout)
(target / (name + '.stderr')).write_bytes(result.stderr)
(target / (name + '.json')).write_text(json.dumps({
    'command': command,
    'cwd': '/workspace/ogent',
    'exit_code': result.returncode,
    'duration_seconds': time.time() - started,
}, indent=2) + '\n')
print(f'{name}: exit={result.returncode}, seconds={time.time() - started:.2f}')
print(result.stdout.decode(errors='replace')[-300:])
print(result.stderr.decode(errors='replace')[-600:])
raise SystemExit(result.returncode)
