import json, pathlib, subprocess
root = pathlib.Path(__file__).resolve().parent/'fixtures'
(root/'glob').mkdir(parents=True, exist_ok=True)
paths=[]
for n in range(105):
    folder = root/'glob' if n % 2 == 0 else root/'glob'/'nested'
    folder.mkdir(exist_ok=True)
    p=folder/f'file-{n:03}.el'
    p.write_text(f';;; fixture {n}\n(defvar fixture-{n} {n})\n')
    paths.append(str(p).replace('/workspace/ogent/', '/work/'))
(root/'search').mkdir(exist_ok=True)
odd = root/'search'/'strange:segment\nline.el'
odd.write_text(''.join(f'needle fixture line {n:03}\n' for n in range(1,251)))
(root/'empty').mkdir(exist_ok=True)
(root/'nonempty').mkdir(exist_ok=True)
(root/'nonempty'/'plain.txt').write_text('plain content\n')
source = ''';;; audit-build.el --- Independent build fixture -*- lexical-binding: t; -*-
;; Author: Audit Fixture
;; Version: 0.1
;; Package-Requires: ((emacs "29.1"))
;;; Commentary:
;; Minimal independently tracked fixture for the real compiler and ERT runner.
;;; Code:
(defun audit-build-add (a b)
  "Add A and B."
  (+ a b))
(provide 'audit-build)
;;; audit-build.el ends here
'''
commands=[]
for name,broken,failing in [('build_success',False,False),('build_compile_failure',True,False),('build_ert_failure',False,True)]:
    project=root/name
    project.mkdir(exist_ok=True)
    (project/'audit-build.el').write_text(source + ('\n)\n' if broken else ''))
    (project/'test').mkdir(exist_ok=True)
    (project/'test'/'audit-build-tests.el').write_text(''';;; audit-build-tests.el --- Fixture ERT -*- lexical-binding: t; -*-
(require 'ert)
(require 'audit-build)
(ert-deftest audit-build-add-test ()
  (should (= (audit-build-add 1 1) %d)))
'''%(3 if failing else 2))
    for cmd in [['git','init','--quiet',str(project)],['git','-C',str(project),'add','audit-build.el','test/audit-build-tests.el']]:
        r=subprocess.run(cmd,capture_output=True,text=True)
        commands.append(dict(command=cmd,stdout=r.stdout,stderr=r.stderr,exit_code=r.returncode))
manifest={'glob_paths':sorted(paths),'search_path':str(odd).replace('/workspace/ogent/','/work/'),'search_line_count':250,'build_setup':commands}
(pathlib.Path(__file__).resolve().parent/'fixture-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(manifest,indent=2))
