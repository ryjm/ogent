import json
import os
import pathlib
import shutil
import subprocess
import tempfile

audit = pathlib.Path(__file__).parent
original = audit / 'tiebreaker-baseline'
rows = []


def run(args, cwd, env=None, scope='generated-file fixture'):
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, timeout=12)
    rows.append(dict(invocation=args, scope=scope, exit_code=result.returncode,
                     stdout=result.stdout, stderr=result.stderr))


with tempfile.TemporaryDirectory(prefix='ogent-tiebreaker-make-') as root:
    fixture = pathlib.Path(root)
    shutil.copyfile(original / 'Makefile', fixture / 'Makefile')
    (fixture / 'lisp/ui').mkdir(parents=True)
    (fixture / 'lisp/source.el').write_text('(provide \'source)\n')
    (fixture / 'lisp/source.elc').write_text('disposable bytecode\n')
    fake_emacs = fixture / 'fake-emacs'
    fake_emacs.write_text('#!/bin/sh\necho fixture-compiler-failed >&2\nexit 23\n')
    fake_emacs.chmod(0o755)
    fake_makem = fixture / 'makem.sh'
    fake_makem.write_text('#!/bin/sh\necho fixture-makem-failed >&2\nexit 23\n')
    fake_makem.chmod(0o755)
    run(['make', 'help'], fixture)
    for target in ['clean', 'compile', 'recompile', 'offline-test']:
        run(['make', '-n', target], fixture, scope='dry-run original recipe')
    run(['make', 'clean'], fixture)
    run(['make', 'clean'], fixture)
    run(['make', 'compile'], fixture, scope='injected compiler failure; recipe forwarding only')
    run(['make', 'recompile', 'EMACS=' + str(fake_emacs)], fixture,
        scope='injected compiler failure; regenerable artifact fixture only')
    for typo in ['cleen', 'compiel', 'recompiel', 'ofline-test']:
        run(['make', typo], fixture, scope='typo delegated to stub makem; forwarding only')

result = subprocess.run([
    'docker', 'exec', 'ogent-fixes', 'env', '-u', 'OGENT_ELPA_DIR', '-u', 'OGENT_GPTEL_DIR',
    'timeout', '12', 'make', '-C',
    '/work/agent_ergonomics_audit/audit/partial/tiebreaker-baseline', 'offline-test'],
    capture_output=True, text=True, timeout=15)
rows.append(dict(invocation='docker exec ogent-fixes env -u OGENT_ELPA_DIR -u OGENT_GPTEL_DIR timeout 12 make -C ORIGINAL_SNAPSHOT offline-test',
                 scope='original local loopback fixture; missing package prerequisite; no provider calls',
                 exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr))
(audit / 'tiebreaker_make_runtime.jsonl').write_text(
    ''.join(json.dumps(row) + '\n' for row in rows))
for row in rows:
    if len(row['stderr']) > 1000:
        row = dict(row, stderr=row['stderr'][:1000])
    print(json.dumps(row))
