import datetime
import json
import pathlib
import subprocess
import sys
import time

root = pathlib.Path('/workspace/ogent')
output = root / 'agent_ergonomics_audit/audit/evidence/pass_3/review_round15'
label, *argv = sys.argv[1:]
start = datetime.datetime.now(datetime.timezone.utc).isoformat()
clock = time.monotonic()
result = subprocess.run(argv, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
end = datetime.datetime.now(datetime.timezone.utc).isoformat()
(output / (label + '.stdout')).write_bytes(result.stdout)
(output / (label + '.stderr')).write_bytes(result.stderr)
record = {'argv': argv, 'host_cwd': str(root), 'start_utc': start, 'end_utc': end,
          'elapsed_seconds': time.monotonic() - clock, 'exit_code': result.returncode,
          'stdout': label + '.stdout', 'stderr': label + '.stderr'}
(output / (label + '.json')).write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record))
for line in result.stderr.decode(errors='replace').splitlines():
    if line.startswith(('REVIEW15', 'Running ', 'Ran ', 'Test ')):
        print(line)
sys.exit(result.returncode)
