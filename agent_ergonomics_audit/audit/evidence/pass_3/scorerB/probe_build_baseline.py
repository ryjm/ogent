import json
import os
from pathlib import Path
import shutil
import subprocess

own=Path('/work/agent_ergonomics_audit/audit/evidence/pass_3/scorerB')
repo=own/'baseline-source'
fixture=own/'baseline-build-fixture'
fixture.mkdir(exist_ok=True)
for name in ('lisp','test'):
    (fixture/name).mkdir(exist_ok=True)
for name in ('Makefile','makem.sh'):
    shutil.copy2(repo/name,fixture/name)
(fixture/'makem.sh').chmod(0o755)
subprocess.run(['git','init','-q',str(fixture)],check=True)
source=''';;; scorer-fixture.el --- Build probe -*- lexical-binding: t; -*-
;; Version: 1.0
;; Package-Requires: ((emacs "29.1"))
;;; Commentary:
;; A minimal local fixture, with no provider requests.
;;; Code:
(defun scorer-fixture-add (value)
  "Return VALUE plus one."
  (1+ value))
(provide 'scorer-fixture)
;;; scorer-fixture.el ends here
'''
test=''';;; scorer-fixture-tests.el --- Local tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'scorer-fixture)
(ert-deftest scorer-fixture-add () (should (= (scorer-fixture-add 1) 2)))
'''
(fixture/'lisp/scorer-fixture.el').write_text(source)
(fixture/'test/scorer-fixture-tests.el').write_text(test)
subprocess.run(['git','add','lisp','test'],cwd=fixture,check=True)
env=dict(os.environ,NO_COLOR='1',CI='true',TERM='dumb')
records=[]
sha=(repo/'TARGET_SHA').read_text().strip()
def run(name,argv,cwd=fixture,environment=env):
    result=subprocess.run(argv,cwd=cwd,env=environment,text=True,capture_output=True,timeout=25)
    records.append(dict(probe=name,target_sha=sha,argv=argv,cwd=str(cwd),exit_code=result.returncode,
                        stdout=result.stdout,stderr=result.stderr,environment={'NO_COLOR':'1','CI':'true','TERM':'dumb'},
                        runtime='ogent-fixes, actual Emacs 30.2, exact baseline makem from git show'))
    print(name,'exit',result.returncode,'stdout',len(result.stdout),'stderr',len(result.stderr))
run('make-help',['make','--no-print-directory','help'])
run('build-help',['./makem.sh','--help'])
run('compile-success-1',['make','--no-print-directory','compile'])
run('compile-success-2',['make','--no-print-directory','compile'])
run('recompile-success',['make','--no-print-directory','recompile'])
run('task-typo',['./makem.sh','compiel'])
(fixture/'lisp/scorer-fixture.el').write_text(source+'(defun scorer-fixture-broken (\n')
run('compile-syntax-failure',['make','--no-print-directory','compile'])
run('recompile-syntax-failure',['make','--no-print-directory','recompile'])
(fixture/'lisp/scorer-fixture.el').write_text(source)
(fixture/'test/scorer-fixture-tests.el').write_text(test.replace('(scorer-fixture-add 1) 2','(scorer-fixture-add 1) 99'))
run('ert-real-failure',['./makem.sh','--no-compile','test'])
for name in ('lisp/scorer-fixture.elc','test/scorer-fixture-tests.elc'):
    (fixture/name).write_text('generated-marker')
run('clean-default',['make','--no-print-directory','clean'])
offline_env=dict(env)
offline_env.pop('OGENT_ELPA_DIR',None);offline_env.pop('OGENT_GPTEL_DIR',None)
(repo/'test/offline/run.sh').chmod(0o755)
run('offline-prerequisite-1',['make','--no-print-directory','offline-test'],cwd=repo,environment=offline_env)
run('offline-prerequisite-2',['make','--no-print-directory','offline-test'],cwd=repo,environment=offline_env)
(own/'baseline-build-runtime.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in records))
shutil.rmtree(fixture/'.git')
