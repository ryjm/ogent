"""Capture scorer-owned transcripts using real source, helpers and Emacs."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path('/workspace/ogent')
OUT = ROOT / 'agent_ergonomics_audit/audit/evidence/pass_3/tiebreaker'
BASELINE = 'b3caf9300c7336ef812ed061158f851c5a47ccf7'
CURRENT = 'a2fa8ce0533b4a508fb641f343fa55b15fd6fc60'

def run(label, argv, *, cwd=ROOT):
    result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=60)
    (OUT / f'{label}.stdout.log').write_text(result.stdout)
    (OUT / f'{label}.stderr.log').write_text(result.stderr)
    record = {'label': label, 'argv': argv, 'exit_code': result.returncode,
              'stdout': f'audit/evidence/pass_3/tiebreaker/{label}.stdout.log',
              'stderr': f'audit/evidence/pass_3/tiebreaker/{label}.stderr.log'}
    (OUT / f'{label}.json').write_text(json.dumps(record, indent=2) + '\n')
    print(f'{label}: exit={result.returncode}; stdout={len(result.stdout)} bytes; stderr={len(result.stderr)} bytes', flush=True)
    return result

def make_probes(phase):
    fixture = OUT / f'fixture-{phase}'
    fixture.mkdir(exist_ok=True)
    (fixture / 'lisp').mkdir(exist_ok=True)
    (fixture / 'test').mkdir(exist_ok=True)
    sha = BASELINE if phase == 'baseline' else CURRENT
    identities = {}
    for filename in ('Makefile', 'makem.sh'):
        content = subprocess.check_output(['git', 'show', f'{sha}:{filename}'], cwd=ROOT)
        (fixture / filename).write_bytes(content)
        identities[filename] = {'source_sha': sha, 'sha256': hashlib.sha256(content).hexdigest()}
    (fixture / 'makem.sh').chmod(0o755)
    source = ''';;; independent-fixture.el --- Actual compiler fixture -*- lexical-binding: t; -*-
;; Version: 1.0
;; Package-Requires: ((emacs "29.1"))
;;; Commentary:
;; Independent scoring fixture with no external requests.
;;; Code:
(defun independent-fixture-add (value)
  "Return VALUE plus one."
  (1+ value))
(provide 'independent-fixture)
;;; independent-fixture.el ends here
'''
    (fixture / 'lisp/independent-fixture.el').write_text(source)
    subprocess.run(['git', 'init', '-q'], cwd=fixture, check=True)
    subprocess.run(['git', 'add', 'lisp'], cwd=fixture, check=True)
    (OUT / f'{phase}-make-source-identities.json').write_text(json.dumps(identities, indent=2) + '\n')
    container_fixture = '/work/' + str(fixture.relative_to(ROOT))
    prefix = ['docker', 'exec', '-w', container_fixture,
              '-e', 'NO_COLOR=1', '-e', 'CI=true', '-e', 'TERM=dumb',
              '-e', 'GIT_CONFIG_COUNT=1', '-e', 'GIT_CONFIG_KEY_0=safe.directory',
              '-e', f'GIT_CONFIG_VALUE_0={container_fixture}',
              '-e', 'SOURCE_DATE_EPOCH=1', 'ogent-fixes']
    run(f'{phase}-make-help', prefix + ['make', '--no-print-directory', 'help'])
    run(f'{phase}-make-recompile-first', prefix + ['make', '--no-print-directory', 'recompile'])
    run(f'{phase}-make-recompile-typo', prefix + ['make', '--no-print-directory', 'recompiel', 'format=json'])
    run(f'{phase}-make-clean-first', prefix + ['make', '--no-print-directory', 'clean'])
    run(f'{phase}-make-clean-repeat', prefix + ['make', '--no-print-directory', 'clean'])
    assert not list(fixture.rglob('*.elc'))
    if phase == 'current':
        run(f'{phase}-make-capabilities', prefix + ['./makem.sh', '--capabilities', '--json'])
        run(f'{phase}-make-recompile-json-first', prefix + ['make', '--no-print-directory', 'recompile', 'format=json'])
        run(f'{phase}-make-recompile-json-repeat', prefix + ['make', '--no-print-directory', 'recompile', 'format=json'])
        run(f'{phase}-make-clean-json', prefix + ['make', '--no-print-directory', 'clean', 'format=json'])
    (fixture / 'lisp/independent-fixture.el').write_text(source + ')\n')
    run(f'{phase}-make-recompile-compiler-failure', prefix + ['make', '--no-print-directory', 'recompile', 'format=json'])
    (fixture / 'lisp/independent-fixture.el').write_text(source)
    if phase == 'current':
        (fixture / 'lisp/independent-fixture.el').write_text(source + '(defun independent-fixture-eof ()\n  (1+ 2)\n')
        run(f'{phase}-make-recompile-eof-failure', prefix + ['make', '--no-print-directory', 'recompile', 'format=json'])
        (fixture / 'lisp/independent-fixture.el').write_text(source)

if __name__ == '__main__':
    phase = sys.argv[1]
    assert phase in ('baseline', 'current')
    if len(sys.argv) > 2 and sys.argv[2] == 'make':
        make_probes(phase)
        sys.exit(0)
    for container, elpa in [('ogent-fixes', '/tmp/ogent-fixdeps/30.2/elpa'),
                            ('ogent-fixes-29', '/tmp/ogent-ergonomics-elpa')]:
        argv = ['docker', 'exec', '-w', '/work', '-e', f'TIEBREAKER_ELPA={elpa}',
                '-e', 'NO_COLOR=1', '-e', 'CI=true', '-e', 'TERM=dumb']
        if phase == 'baseline':
            argv += ['-e', 'TIEBREAKER_BASELINE=1']
        argv += [container, 'emacs', '-Q', '--batch', '-l',
                 'agent_ergonomics_audit/audit/evidence/pass_3/tiebreaker/paired-sdk.el']
        run(f'{phase}-sdk-{container}', argv)
