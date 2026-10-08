import json, os, pathlib, shlex, subprocess, sys, time
from datetime import datetime, timezone
ROOT=pathlib.Path('/workspace/ogent/agent_ergonomics_audit/audit/agent_simulations/pre_pass_1/canonical')
def now(): return datetime.now(timezone.utc).isoformat()
def cap(s): return s if len(s.encode())<=4096 else s.encode()[:4096].decode(errors='replace')+'\n... [truncated]'
x=json.load(sys.stdin); n=x['task_number']; slug=x['task_slug']; stem=f'task-{n:02d}-{slug}'; log=ROOT/(stem+'.transcript.jsonl')
if not log.exists(): log.write_text(json.dumps({'_meta':True,'task_number':n,'task_slug':slug,'started_at':now(),'completed_at':None})+'\n')
step=sum(1 for _ in log.open())
argv=x['argv']; ran_at=now(); start=time.monotonic()
p=subprocess.run(argv,cwd=x.get('cwd'),env=os.environ|x.get('env',{}),input=x.get('stdin_data'),text=True,capture_output=True)
stdout_file=ROOT/f'{stem}.step-{step:02d}.stdout.txt'; stderr_file=ROOT/f'{stem}.step-{step:02d}.stderr.txt'; stdout_file.write_text(p.stdout); stderr_file.write_text(p.stderr)
r={k:x.get(k) for k in ['intent','cwd','stdin_data']}; r.update(task_slug=slug,task_number=n,stage='pre',pass_=1,step=step,invocation=shlex.join(argv),argv=argv,env=x.get('env',{}),exit_code=p.returncode,stdout=cap(p.stdout),stderr=cap(p.stderr),elapsed_ms=round((time.monotonic()-start)*1000),outcome=x.get('outcome','partial'),ran_at=ran_at,stdout_artifact=stdout_file.name,stderr_artifact=stderr_file.name)
r['pass']=r.pop('pass_')
if 'sdk_expression' in x:r['sdk_expression']=x['sdk_expression']
with log.open('a') as f:f.write(json.dumps(r)+'\n')
print(json.dumps(r,indent=2))
