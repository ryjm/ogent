"""Protected source-forced probes of an immutable production freeze."""
import datetime,hashlib,json,os,pathlib,subprocess
repo=pathlib.Path('/workspace/ogent');f=repo/'agent_ergonomics_audit/audit/evidence/pass_3/scorerA'
sha=subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip()
paths=['lisp/ogent-agent.el','lisp/ogent-tools.el','lisp/ogent-models.el','lisp/ogent-tool-execution.el','lisp/ogent-tool-process.el','lisp/ogent-tool-results.el','lisp/ogent-doctor.el','lisp/ui/ogent-ui-toolcalls.el','test/ogent-agent-execution-tests.el','test/ui/ogent-ui-toolcalls-tests.el','Makefile','makem.sh','test/offline/run.sh']
hashes={p:hashlib.sha256((repo/p).read_bytes()).hexdigest() for p in paths}
for p in paths:assert (repo/p).read_bytes()==subprocess.check_output(['git','show',sha+':'+p],cwd=repo),p+' differs from freeze'
records=[]
pending={}
for stem,script,real_gptel in [('sdk','probe_sdk.el',False),('registry','probe_registry.el',True),('boundary','probe_boundary.el',False),('ledger','probe_ledger.el',False)]:
 argv=['docker','exec','-e','NO_COLOR=1','-e','CI=true','-e','TERM=dumb','ogent-fixes','emacs','-Q','--batch','-L','/work/lisp','-L','/work/lisp/ui','-L','/work/test']
 if real_gptel:argv+=['-L','/tmp/ogent-fixdeps/30.2/elpa/compat-31.1.0.0']
 argv+=['-l','/work/test/ogent-test-helper.el','-l','/work/agent_ergonomics_audit/audit/evidence/pass_3/scorerA/'+script]
 r=subprocess.run(argv,text=True,capture_output=True,timeout=45)
 pending[stem+'_runtime.stderr']=r.stderr
 assert r.returncode==0,(stem,r.returncode,r.stderr[-2000:])
 data=[json.loads(x) for x in r.stdout.splitlines()]
 for v in data:v['target_sha']=sha
 pending[stem+'_runtime.jsonl']=''.join(json.dumps(v,ensure_ascii=False)+'\n' for v in data)
 records.append({'probe_family':stem,'target_sha':sha,'argv':argv,'exit_code':r.returncode,'records':len(data),'source_assertion':'symbol-file read-file equals /work/lisp/ogent-tools.el'})
 print(stem,r.returncode,len(data))
r=subprocess.run(['python3',str(f/'probe_make.py')],cwd=repo,text=True,capture_output=True,timeout=60,env={**os.environ,'SCORERA_MAKE_OUTPUT':'.make_runtime_staged.jsonl'})
assert r.returncode==0,r.stderr
print(r.stdout,end='')
rows=[json.loads(x) for x in (f/'.make_runtime_staged.jsonl').read_text().splitlines()]
for row in rows:row.setdefault('target_sha',sha)
pending['make_runtime.jsonl']=''.join(json.dumps(v,ensure_ascii=False)+'\n' for v in rows)
records.append({'probe_family':'actual-makem-small-independent-fixture','target_sha':sha,'argv':['python3','audit/evidence/pass_3/scorerA/probe_make.py'],'exit_code':r.returncode,'records':len(rows)})
assert sha==subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),'HEAD changed during run'
assert all(hashlib.sha256((repo/p).read_bytes()).hexdigest()==h for p,h in hashes.items()),'Source changed during run'
for name,data in pending.items():
 (f/name).write_text(data)
(f/'.make_runtime_staged.jsonl').unlink()
(f/'current_runtime_provenance.json').write_text(json.dumps({'target_sha':sha,'utc_finished':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source_sha256':hashes,'runs':records,'method':'Same-model qualitative judgment, not agent-success measurements. No providers; protected source-force helper and real tiny compiler fixture.'},indent=2)+'\n')
