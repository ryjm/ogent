import json
import os
from pathlib import Path
import shutil
import subprocess

repo = Path('/work')
evidence = repo / 'agent_ergonomics_audit/audit/evidence/pass_3/scorerB'
fixture = evidence / 'build-fixture'
fixture.mkdir(exist_ok=True)
for name in ('lisp', 'test'):
    (fixture / name).mkdir(exist_ok=True)
for name in ('Makefile', 'makem.sh'):
    shutil.copy2(repo / name, fixture / name)
subprocess.run(['git', 'init', '-q', str(fixture)], check=True)
source = ''';;; scorer-fixture.el --- Build probe -*- lexical-binding: t; -*-
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
test = ''';;; scorer-fixture-tests.el --- Local tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'scorer-fixture)
(ert-deftest scorer-fixture-add () (should (= (scorer-fixture-add 1) 2)))
'''
(fixture / 'lisp/scorer-fixture.el').write_text(source)
(fixture / 'test/scorer-fixture-tests.el').write_text(test)
subprocess.run(['git', 'add', 'lisp', 'test'], cwd=fixture, check=True)
env = dict(os.environ, NO_COLOR='1', CI='true', TERM='dumb')
records = []
sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()

def run(name, argv, cwd=fixture, environment=env):
    result = subprocess.run(argv, cwd=cwd, env=environment, text=True, capture_output=True, timeout=25)
    (evidence / (name + '.stdout')).write_text(result.stdout)
    (evidence / (name + '.stderr')).write_text(result.stderr)
    item = dict(probe=name, target_sha=sha, argv=argv, cwd=str(cwd), exit_code=result.returncode,
                stdout=result.stdout, stderr=result.stderr, environment={'NO_COLOR':'1','CI':'true','TERM':'dumb'},
                runtime='ogent-fixes, actual Emacs 30.2, actual copied makem.sh')
    records.append(item)
    print(name, 'exit', result.returncode, 'stdout', len(result.stdout), 'stderr', len(result.stderr))

run('make-help', ['make', '--no-print-directory', 'help'])
run('build-capabilities', ['./makem.sh', '--capabilities', '--json'])
run('compile-success-1', ['make', '--no-print-directory', 'compile', 'format=json'])
run('compile-success-2', ['make', '--no-print-directory', 'compile', 'format=json'])
run('recompile-success', ['make', '--no-print-directory', 'recompile', 'format=json'])
run('test-success', ['./makem.sh', '--json', '--no-compile', 'test'])
run('task-typo', ['./makem.sh', '--json', 'compiel'])
run('emacs-option-typo', ['./makem.sh', '--json', '--emaxx=emacs', 'compile'])
(fixture / 'lisp/scorer-fixture.el').write_text(source + '(defun scorer-fixture-broken () missing-variable)\n')
run('compile-warning-failure', ['make', '--no-print-directory', 'compile', 'format=json'])
run('lint-compile-warning-failure', ['./makem.sh', '--json', 'lint-compile'])
run('recompile-warning-failure', ['make', '--no-print-directory', 'recompile', 'format=json'])
(fixture / 'lisp/scorer-fixture.el').write_text(source + '(defun scorer-fixture-broken (\n')
run('compile-syntax-failure', ['make', '--no-print-directory', 'compile', 'format=json'])
run('recompile-syntax-failure', ['make', '--no-print-directory', 'recompile', 'format=json'])
(fixture / 'lisp/scorer-fixture.el').write_text(source)
(fixture / 'test/scorer-fixture-tests.el').write_text(test.replace('(scorer-fixture-add 1) 2', '(scorer-fixture-add 1) 99'))
run('ert-real-failure', ['./makem.sh', '--json', '--no-compile', 'test'])
for name in ('lisp/scorer-fixture.elc','test/scorer-fixture-tests.elc'):
    (fixture/name).write_text('generated-marker')
run('clean-default', ['make', '--no-print-directory', 'clean'])
for name in ('lisp/scorer-fixture.elc','test/scorer-fixture-tests.elc'):
    (fixture/name).write_text('generated-marker')
run('clean-json', ['make', '--no-print-directory', 'clean', 'format=json'])
remaining = {'source_preserved': (fixture/'lisp/scorer-fixture.el').read_text() == source,
             'lisp_bytecode_removed': not (fixture/'lisp/scorer-fixture.elc').exists(),
             'test_bytecode_removed': not (fixture/'test/scorer-fixture-tests.elc').exists()}
(evidence / 'clean-state.json').write_text(json.dumps(remaining, indent=2)+'\n')
offline_env = dict(env)
offline_env.pop('OGENT_ELPA_DIR',None)
offline_env.pop('OGENT_GPTEL_DIR',None)
run('offline-prerequisite-1', ['make','--no-print-directory','offline-test'], cwd=repo, environment=offline_env)
run('offline-prerequisite-2', ['make','--no-print-directory','offline-test'], cwd=repo, environment=offline_env)
(evidence / 'build-runtime.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in records))
# The nested Git index is only a minimal makem discovery fixture, not an audit repo.
shutil.rmtree(fixture/'.git')
