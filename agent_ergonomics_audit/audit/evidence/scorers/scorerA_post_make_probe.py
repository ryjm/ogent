import json
import pathlib
import shutil
import subprocess
import tempfile

root = pathlib.Path('/workspace/ogent')
partial = root / 'agent_ergonomics_audit/audit/partial'
rows = []

def run(probe, argv, cwd=root):
    result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=15)
    rows.append(dict(probe=probe, invocation=argv, exit_code=result.returncode,
                     stdout=result.stdout, stderr=result.stderr))

for probe, argv in [
    ('help-1', ['make', 'help']),
    ('help-2', ['make', 'help']),
    ('compile-dry', ['make', '-n', 'compile']),
    ('clean-dry', ['make', '-n', 'clean']),
    ('recompile-dry', ['make', '-n', 'recompile']),
    ('offline-test-dry', ['make', '-n', 'offline-test']),
    ('compile-help', ['make', '-n', 'compile', 'help']),
    ('typo-dry', ['make', '-n', 'recomiple']),
    ('offline-missing-deps', ['env', '-u', 'OGENT_ELPA_DIR', 'make', 'offline-test'])
]:
    run(probe, argv)

with tempfile.TemporaryDirectory(prefix='scorerA-post-make-', dir=partial) as folder:
    fixture = pathlib.Path(folder)
    shutil.copyfile(root / 'Makefile', fixture / 'Makefile')
    (fixture / 'lisp/ui').mkdir(parents=True)
    (fixture / 'test').mkdir()
    shutil.copyfile(root / 'makem.sh', fixture / 'makem.sh')
    (fixture / 'makem.sh').chmod(0o755)
    (fixture / 'lisp/fixture.el').write_text('(provide \'fixture)\n')
    (fixture / 'lisp/fixture.elc').write_text('disposable bytecode\n')
    fake = fixture / 'fake-emacs'
    fake.write_text('#!/bin/sh\necho "intentional compiler failure" >&2\nexit 23\n')
    fake.chmod(0o755)
    run('recompile-failing-emacs', ['make', 'recompile', 'EMACS=' + str(fake)], fixture)
    rows[-1]['bytecode_removed'] = not (fixture / 'lisp/fixture.elc').exists()
    run('clean-1', ['make', 'clean'], fixture)
    run('clean-2', ['make', 'clean'], fixture)

(partial / 'scorerA_post_make_runtime.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
print(json.dumps(rows, indent=2))
