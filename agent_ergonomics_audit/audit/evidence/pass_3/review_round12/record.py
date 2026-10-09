import datetime
import json
import pathlib
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parent
name = sys.argv[1]
argv = sys.argv[2:]
start = datetime.datetime.now(datetime.timezone.utc).isoformat()
t0 = time.monotonic()
try:
    p = subprocess.run(argv, cwd='/workspace/ogent', capture_output=True, timeout=120)
    code, stdout, stderr = p.returncode, p.stdout, p.stderr
except subprocess.TimeoutExpired as e:
    code, stdout, stderr = 124, e.stdout or b'', e.stderr or b''
    stderr += b'\nRECORDER TIMEOUT at 120s\n'
(root / (name + '.stdout')).write_bytes(stdout)
(root / (name + '.stderr')).write_bytes(stderr)
record = dict(argv=argv, cwd='/workspace/ogent', start_utc=start,
              end_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
              duration_seconds=time.monotonic()-t0, exit_code=code,
              stdout=name+'.stdout', stderr=name+'.stderr')
(root / (name+'.json')).write_text(json.dumps(record, indent=2)+'\n')
print(json.dumps(record))
print(stdout.decode(errors='replace')[-1500:])
print(stderr.decode(errors='replace')[-2500:])
