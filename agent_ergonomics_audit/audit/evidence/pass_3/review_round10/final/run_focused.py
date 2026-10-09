import concurrent.futures,datetime,json,pathlib,re,subprocess,time
out=pathlib.Path(__file__).resolve().parent
containers=['ogent-fixes','ogent-fixes-29']
versions={}
for container in containers:
 versions[container]={}
 for label,argv in [('emacs',['emacs','--version']),('ripgrep',['/tmp/ogent-test-rg','--version'])]:
  p=subprocess.run(['docker','exec',container,*argv],capture_output=True,text=True,timeout=20)
  versions[container][label]={'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
  assert p.returncode==0
(out/'runtime_versions.json').write_text(json.dumps(versions,indent=2)+'\n')
def run(container):
 argv=['docker','exec','-e','OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg',container,'emacs','-Q','--batch','-L','/work/lisp','-L','/work/lisp/ui','-L','/work/test','-L','/work/test/ui','-l','/work/test/ogent-test-helper.el','-l','/work/test/ogent-agent-execution-tests.el','-l','/work/test/ogent-tool-process-tests.el','-l','/work/test/ui/ogent-ui-toolcalls-tests.el','--eval','(ert-run-tests-batch-and-exit t)']
 start=datetime.datetime.now(datetime.timezone.utc).isoformat();t=time.monotonic()
 p=subprocess.run(argv,capture_output=True,text=True,timeout=120)
 elapsed=time.monotonic()-t
 (out/(container+'.stdout')).write_text(p.stdout)
 (out/(container+'.stderr')).write_text(p.stderr)
 transcript=p.stdout+p.stderr
 matches=re.findall(r'Ran (\d+) tests, (\d+) results as expected, (\d+) unexpected(?:, (\d+) skipped)?',transcript)
 assert matches, transcript[-1000:]
 selected,expected,unexpected,skipped=matches[-1]
 record={'container':container,'argv':argv,'started':start,'elapsed_seconds':elapsed,'exit':p.returncode,'counts':{'selected':int(selected),'expected':int(expected),'unexpected':int(unexpected),'skipped':int(skipped or 0)}}
 (out/(container+'.json')).write_text(json.dumps(record,indent=2)+'\n')
 return record
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
 for r in pool.map(run,containers):print(json.dumps(r),flush=True)
