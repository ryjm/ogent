"""Paired wrapper probes; fake Emacs never generates actual bytecode."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[4]
out = Path(__file__).parent
baseline = repo / "agent_ergonomics_audit/audit/partial/tiebreaker-baseline"
rows = []

def run(stage, label, command, cwd, env):
    result = subprocess.run(command, cwd=cwd, env=env, capture_output=True,
                            text=True, timeout=18)
    rows.append(dict(stage=stage, probe=label, invocation=command,
                     scope="isolated fixture; synthetic .elc markers; fake compiler writes no bytecode",
                     exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr))

for stage, source in [("baseline", baseline), ("post", repo)]:
    with tempfile.TemporaryDirectory(prefix="ogent-reconcile-") as tmp:
        root = Path(tmp)
        (root / "lisp/ui").mkdir(parents=True)
        (root / "test").mkdir()
        for name in ("Makefile", "makem.sh"):
            shutil.copy2(source / name, root / name)
        (root / "lisp/ogent.el").write_text(
            ";;; ogent.el --- Probe -*- lexical-binding: t; -*-\n"
            ";; Version: 0.1\n;; Package-Requires: ((emacs \"29.1\"))\n"
            "(provide 'ogent)\n")
        # Actual makem discovers tracked Elisp files. This disposable index
        # satisfies that prerequisite without creating any git commit.
        subprocess.run(["git", "init", "--quiet", str(root)], check=True)
        subprocess.run(["git", "add", "--", "lisp/ogent.el"], cwd=root, check=True)
        for name in ("lisp/marker.elc", "test/marker.elc"):
            (root / name).write_text("synthetic disposable marker, not compiler output\n")
        script = ('#!/bin/sh\n'
                  'printf "%s\\n" "$0 $*" >> "$OGENT_RECONCILE_TRACE"\n'
                  'case "$*" in\n'
                  ' *"princ emacs-version"*) printf "30.2"; exit 0 ;;\n'
                  ' *"princ lisp-directory"*) printf "%s" "$OGENT_RECONCILE_LISP"; exit 0 ;;\n'
                  'esac\n'
                  'printf "%s\\n" "fixture compiler failed" >&2\nexit 23\n')
        for executable in ("emacs", "selected-emacs"):
            (root / executable).write_text(script)
            (root / executable).chmod(0o755)
        env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                   OGENT_RECONCILE_TRACE=str(root / "compiler.trace"),
                   OGENT_RECONCILE_LISP=str(root / "empty-lisp"),
                   NO_COLOR="1", CI="true", TERM="dumb")
        (root / "empty-lisp").mkdir()
        run(stage, "help", ["make", "help"], root, env)
        run(stage, "clean-first", ["make", "clean"], root, env)
        rows[-1]["source_preserved"] = (root / "lisp/ogent.el").exists()
        rows[-1]["test_marker_preserved"] = (root / "test/marker.elc").exists()
        run(stage, "clean-repeat", ["make", "clean"], root, env)
        for target in ("compile", "recompile"):
            trace = root / "compiler.trace"
            trace.unlink(missing_ok=True)
            run(stage, target + "-actual-makem-failure",
                ["make", target, "EMACS=" + str(root / "selected-emacs")], root, env)
            rows[-1]["compiler_calls"] = trace.read_text().splitlines() if trace.exists() else []
            rows[-1]["ansi_in_stdout"] = "\x1b[" in rows[-1]["stdout"]
            rows[-1]["ansi_in_stderr"] = "\x1b[" in rows[-1]["stderr"]
        for typo in ("cleen", "compiel", "recompiel", "ofline-test"):
            run(stage, "typo-" + typo, ["make", typo], root, env)

for stage, source in [("baseline", "/work/agent_ergonomics_audit/audit/partial/tiebreaker-baseline"),
                      ("post", "/work")]:
    command = ["docker", "exec", "-w", source, "ogent-fixes", "env", "-u", "OGENT_ELPA_DIR",
               "-u", "OGENT_GPTEL_DIR", "NO_COLOR=1", "CI=true", "TERM=dumb", "timeout", "12",
               "make", "--no-print-directory", "offline-test"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=17)
    rows.append(dict(stage=stage, probe="offline-missing-prerequisite", invocation=command,
                     scope="missing prerequisites; baseline local fixture with cleanup, post preflight",
                     exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr))
    if stage == "post":
        result = subprocess.run(command, capture_output=True, text=True, timeout=17)
        rows.append(dict(stage=stage, probe="offline-missing-prerequisite-repeat", invocation=command,
                         scope="post preflight, no fixture or provider created",
                         exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr))

(out / "make_runtime.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
for row in rows:
    print(json.dumps({k: v if k not in ("stdout", "stderr", "compiler_calls") else
                      (v[:1100] if isinstance(v, str) else v[:3]) for k, v in row.items()}))
