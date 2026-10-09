import datetime, hashlib, json, pathlib, re, subprocess, sys, time
repo = pathlib.Path('/workspace/ogent')
out = repo/'agent_ergonomics_audit/audit/evidence/pass_3/review_round14'
def now(): return datetime.datetime.now(datetime.timezone.utc).isoformat()
def git(*args): return subprocess.check_output(['git',*args], cwd=repo).decode().strip()
def guard(name):
    paths = [p for p in git('ls-files','-z').split('\0') if p and not p.startswith(('agent_ergonomics_audit/','.beads/','.beads-legacy-bd/'))]
    data = {'time':now(),'head':git('rev-parse','HEAD'),'branch':git('branch','--show-current'),'hashes':{p:hashlib.sha256((repo/p).read_bytes()).hexdigest() for p in paths if (repo/p).is_file()},'staged_paths':[p for p in git('diff','--cached','--name-only').splitlines() if p in paths],'unstaged_paths':[p for p in git('diff','--name-only').splitlines() if p in paths],'status_full':git('status','--porcelain=v1')}
    (out/(name+'.json')).write_text(json.dumps(data,indent=2)+'\n')
    print(json.dumps({k:v for k,v in data.items() if k not in ('hashes','status_full')}|{'tracked_hash_count':len(data['hashes'])}))
if sys.argv[1] == 'guard': guard(sys.argv[2])
else:
    name, argv = sys.argv[1], sys.argv[2:]
    began, timer = now(), time.monotonic()
    result = subprocess.run(argv,cwd=repo,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    (out/(name+'.stdout')).write_bytes(result.stdout)
    (out/(name+'.stderr')).write_bytes(result.stderr)
    record = {'argv':argv,'cwd':str(repo),'start':began,'end':now(),'elapsed_seconds':time.monotonic()-timer,'exit':result.returncode,'stdout':name+'.stdout','stderr':name+'.stderr'}
    summary = re.search(r'Ran (\d+) tests?, (\d+) results as expected, (\d+) unexpected(?:, (\d+) skipped)?', (result.stdout + result.stderr).decode(errors='replace'))
    if summary:
        total, expected, unexpected, skipped = summary.groups()
        record['ert'] = {'selected':int(total), 'expected':int(expected), 'unexpected':int(unexpected), 'skipped':int(skipped or 0)}
    (out/(name+'.json')).write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps(record)); print(result.stdout.decode(errors='replace')[-2000:]); print(result.stderr.decode(errors='replace')[-3000:])
