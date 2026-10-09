"""Independently run exact Makefile/makem with small real Emacs fixture."""
import hashlib, json, os, pathlib, shutil, subprocess
repo=pathlib.Path('/workspace/ogent')
evidence=repo/'agent_ergonomics_audit/audit/evidence/pass_3/scorerA'
fixture=evidence/'baseline_make_fixture'
fixture.mkdir(exist_ok=True)
(fixture/'lisp').mkdir(exist_ok=True)
(fixture/'test').mkdir(exist_ok=True)
for name in ('Makefile','makem.sh'):
    shutil.copy2(evidence/'baseline_sources'/name,fixture/name)
subprocess.run(['git','init','-q',str(fixture)],check=True)
source=fixture/'lisp/scorera-fixture.el'
source.write_text(''';;; scorera-fixture.el --- Independent real compiler fixture -*- lexical-binding: t; -*-
;; Version: 1.0
;; Package-Requires: ((emacs "29.1"))
;;; Commentary:
;; Local fixture without ogent or provider dependencies.
;;; Code:
(defun scorera-fixture-add (n)
  "Return N plus one."
  (1+ n))
(provide 'scorera-fixture)
;;; scorera-fixture.el ends here
''')
subprocess.run(['git','-C',str(fixture),'add','lisp'],check=True)
cwd='/work/'+str(fixture.relative_to(repo))
records=[]
def run(label,args):
    full=['docker','exec','-e','NO_COLOR=1','-e','CI=true','-e','TERM=dumb','-e','GIT_CONFIG_COUNT=1','-e','GIT_CONFIG_KEY_0=safe.directory','-e','GIT_CONFIG_VALUE_0='+cwd,'-w',cwd,'ogent-fixes',*args]
    p=subprocess.run(full,text=True,capture_output=True,timeout=45)
    record={'probe':label,'target_sha':'b3caf9300c7336ef812ed061158f851c5a47ccf7','makem_sha256':hashlib.sha256((fixture/'makem.sh').read_bytes()).hexdigest(),'argv':full,'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
    try: record['report']=json.loads(p.stdout)
    except ValueError: pass
    records.append(record)
    (evidence/'baseline_make_runtime.jsonl').write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in records))
    print(label,p.returncode,len(p.stdout),len(p.stderr))
run('help-1',['make','--no-print-directory','help'])
run('help-2',['make','--no-print-directory','help'])
run('compile-human-1',['make','--no-print-directory','compile','EMACS=emacs'])
run('compile-human-2',['make','--no-print-directory','compile','EMACS=emacs'])
run('recompile-human',['make','--no-print-directory','recompile','EMACS=emacs'])
run('clean-human-1',['make','--no-print-directory','clean'])
run('clean-human-2',['make','--no-print-directory','clean'])
run('baseline-json-unavailable',['bash','./makem.sh','--json','compile'])
source.write_text(source.read_text()+'\n(defun scorera-fixture-broken ()\n')
run('compile-human-failure',['make','--no-print-directory','compile','EMACS=emacs'])
run('recompile-human-failure',['make','--no-print-directory','recompile','EMACS=emacs'])
run('typo',['make','--no-print-directory','compiel','EMACS=emacs'])
# Run the archived actual offline script only through its preflight.
full=['docker','exec','-e','OGENT_ELPA_DIR=','-e','OGENT_GPTEL_DIR=','-w',cwd,'ogent-fixes','bash','../baseline_sources/test/offline/run.sh']
p=subprocess.run(full,text=True,capture_output=True,timeout=10)
records.append({'probe':'offline-prerequisite','target_sha':'b3caf9300c7336ef812ed061158f851c5a47ccf7','argv':full,'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
(evidence/'baseline_make_runtime.jsonl').write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in records))
