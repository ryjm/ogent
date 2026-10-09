import argparse, json, pathlib, subprocess, time
p = argparse.ArgumentParser()
p.add_argument('name')
p.add_argument('command', nargs=argparse.REMAINDER)
a = p.parse_args()
root = pathlib.Path(__file__).resolve().parent
started = time.time()
r = subprocess.run(a.command, cwd='/workspace/ogent', capture_output=True)
record = {'command': a.command, 'cwd': '/workspace/ogent', 'started_unix': started,
          'duration_seconds': time.time()-started, 'exit_code': r.returncode,
          'stdout': r.stdout.decode('utf-8', errors='replace'),
          'stderr': r.stderr.decode('utf-8', errors='replace')}
(root/(a.name+'.json')).write_text(json.dumps(record, ensure_ascii=False, indent=2)+'\n')
(root/(a.name+'.stdout')).write_bytes(r.stdout)
(root/(a.name+'.stderr')).write_bytes(r.stderr)
print(json.dumps({k:v for k,v in record.items() if k not in ('stdout','stderr')} | {'stdout_bytes':len(r.stdout),'stderr_bytes':len(r.stderr)}, ensure_ascii=False, indent=2))
