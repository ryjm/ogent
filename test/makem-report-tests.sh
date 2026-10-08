#!/usr/bin/env bash
# Exercise the real makem runner with a tracked, provider-free Elisp fixture.
set -euo pipefail

report_test_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
report_test_makem=${MAKEM_UNDER_TEST:-$report_test_root/makem.sh}
report_test_emacs=${EMACS:-emacs}
report_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ogent-makem-report-tests.XXXXXX")
trap 'rm -rf "$report_test_dir"' EXIT
mkdir -p "$report_test_dir/lisp" "$report_test_dir/test"
cp "$report_test_makem" "$report_test_dir/makem.sh"
cp "$report_test_root/Makefile" "$report_test_dir/Makefile"
chmod +x "$report_test_dir/makem.sh"
cd "$report_test_dir"
git init -q

cat > lisp/report-fixture.el <<'ELISP'
;;; report-fixture.el --- Structured build fixture -*- lexical-binding: t; -*-
;; Version: 1.0
;; Package-Requires: ((emacs "29.1"))
;;; Commentary:
;; Exercise the actual build helper without contacting a provider.
;;; Code:
(defun report-fixture-add (value)
  "Return VALUE plus one."
  (1+ value))
(provide 'report-fixture)
;;; report-fixture.el ends here
ELISP
cat > test/report-fixture-tests.el <<'ELISP'
;;; report-fixture-tests.el --- Build tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'report-fixture)
(ert-deftest report-fixture-increments ()
  "Check the real fixture result."
  (should (= (report-fixture-add 1) 2)))
ELISP
git add lisp test

# Every invocation gets an independent parse; extra stdout breaks json.load.
function run-report {
    local expected=$1
    shift
    local actual=0
    "$@" > "$report_test_dir/output.json" 2> "$report_test_dir/diagnostics.txt" || actual=$?
    if [[ $actual != "$expected" ]]
    then
        printf 'Expected exit %s, got %s: %s\n' "$expected" "$actual" "$*" >&2
        cat "$report_test_dir/diagnostics.txt" >&2
        return 1
    fi
    python3 - "$report_test_dir/output.json" "$expected" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    report = json.load(stream)
assert report["contract_version"] == "1", report
assert report["tool"] == "makem.sh", report
assert report["exit_code"] == int(sys.argv[2]), report
assert report["status"] == ("success" if int(sys.argv[2]) == 0 else "error"), report
assert "\x1b[" not in open(sys.argv[1]).read(), report
PY
}

run-report 0 ./makem.sh --json --capabilities
python3 - <<'PY'
import json
r = json.load(open("output.json"))
assert "test-ert" in r["capabilities"]["rules"]
assert r["exit_codes"]["2"] == "invalid_invocation"
assert r["commands"] == []
PY

run-report 2 ./makem.sh --json --emacs=/unavailable/emacs tset
python3 - <<'PY'
import json
r = json.load(open("output.json"))
assert r["commands"] == []
assert "make test" in r["next_actions"]
assert "Unknown task 'tset'" in r["diagnostics"][0]["message"]
PY
run-report 2 ./makem.sh --json --emaxx="$report_test_emacs" compile
run-report 2 ./makem.sh --json
run-report 2 ./makem.sh --json interactive
run-report 3 ./makem.sh --json --emacs=/unavailable/emacs compile
run-report 0 ./makem.sh --json --help

# Bootstrap errors still produce the same root contract without Python.
mkdir bootstrap-bin
ln -s "$(command -v bash)" bootstrap-bin/bash
run-report 3 env PATH="$report_test_dir/bootstrap-bin" ./makem.sh --json --capabilities
python3 - <<'PY'
import json
r = json.load(open("output.json"))
assert r["commands"] == [] and r["tasks"] == []
assert "python3" in r["diagnostics"][0]["message"]
assert r["exit_codes"]["3"] == "missing_prerequisite"
PY

run-report 0 ./makem.sh --json --emacs="$report_test_emacs" compile
test -s lisp/report-fixture.elc
python3 - <<'PY'
import json
r = json.load(open("output.json"))
assert r["requested_tasks"] == ["compile"]
assert r["tasks"] == [{"name": "compile", "status": "success", "exit_code": 0, "reason": None}]
assert r["commands"] and all(c["exit_code"] == 0 for c in r["commands"])
assert any("makem-byte-compile-file" in " ".join(c["argv"]) for c in r["commands"])
PY

run-report 0 ./makem.sh --json --emacs="$report_test_emacs" --no-compile test
python3 - <<'PY'
import json
r = json.load(open("output.json"))
assert any(t["name"] == "test-ert" and t["status"] == "success" for t in r["tasks"])
assert any(t["name"] == "test-buttercup" and t["status"] == "skipped" for t in r["tasks"])
summaries = [c["tests"] for c in r["commands"] if "tests" in c]
assert summaries == [{"total": 1, "expected": 1, "unexpected": 0, "skipped": 0}], summaries
assert not any(d["severity"] == "error" for d in r["diagnostics"]), r
PY

run-report 1 ./makem.sh --json --emacs="$report_test_emacs" --no-compile test-buttercup
python3 - <<'PY'
import json
r = json.load(open("output.json"))
assert r["tasks"][-1]["status"] == "error"
assert "Buttercup tests not found" in r["diagnostics"][0]["message"]
PY
run-report 0 ./makem.sh --json --emacs="$report_test_emacs" --no-compile --exclude=test/report-fixture-tests.el test
python3 - <<'PY'
import json
r = json.load(open("output.json"))
assert r["commands"] == []
assert len([t for t in r["tasks"] if t["status"] == "skipped"]) == 2
PY

# The Make target invokes this same actual helper, not a fixture replacement.
run-report 0 make --no-print-directory test format=json EMACS="$report_test_emacs"
python3 - <<'PY'
import json
r = json.load(open("output.json"))
assert r["commands"] and r["requested_tasks"] == ["test"]
PY

run-report 0 make --no-print-directory recompile format=json EMACS="$report_test_emacs"
python3 - <<'PY'
import json
r = json.load(open("output.json"))
assert r["requested_tasks"] == ["compile"] and r["commands"]
PY

# Batch arguments and output are serialized exactly, including Unicode.
run-report 0 ./makem.sh --json --emacs="$report_test_emacs" --no-compile batch -- --eval '(progn (princ "quote\" newline\n") (princ (decode-coding-string (unibyte-string 233 155 170) (quote utf-8))))' --eval '(ignore "雪")'
python3 - <<'PY'
import json
r = json.load(open("output.json"))
assert any(c["output"] == 'quote" newline\n雪' for c in r["commands"]), r
assert any('雪' in argument for c in r["commands"] for argument in c["argv"])
PY

# Exercise real compiler diagnostics and warnings-as-errors, with locations.
cat >> lisp/report-fixture.el <<'ELISP'
(defun report-fixture-broken ()
  "Return an intentionally undeclared variable."
  report-fixture-missing)
ELISP
run-report 1 ./makem.sh --json --emacs="$report_test_emacs" lint-compile
python3 - <<'PY'
import json
r = json.load(open("output.json"))
assert any(t["name"] == "lint-compile" and t["status"] == "error" for t in r["tasks"])
assert any(c["exit_code"] != 0 for c in r["commands"])
assert any(d["file"] == "lisp/report-fixture.el" and d["line"] > 0 for d in r["diagnostics"]), r
assert any("report-fixture-missing" in c["output"] for c in r["commands"])
PY

# Syntax diagnostics can put positions in prose instead of the file prefix.
cat > lisp/report-fixture.el <<'ELISP'
;;; Malformed syntax fixture.
(defun report-fixture-add (value) (1+ value))
(provide 'report-fixture)
)
ELISP
run-report 1 ./makem.sh --json --emacs="$report_test_emacs" compile
python3 - <<'PY'
import json
r = json.load(open("output.json"))
assert any(d["file"] == "lisp/report-fixture.el" and d["line"] == 4 and d["column"] == 1
           for d in r["diagnostics"]), r
PY

# A parser error can name the source without publishing line/column positions.
cp lisp/report-fixture.el syntax-fixture.saved
cat > lisp/report-fixture.el <<'ELISP'
;;; EOF parser fixture -*- lexical-binding: t; -*-
(defun report-fixture-add (value)
  (1+ value)
(provide 'report-fixture)
ELISP
run-report 1 ./makem.sh --json --emacs="$report_test_emacs" compile
python3 - <<'PY'
import json
r = json.load(open("output.json"))
assert any(d["file"] == "lisp/report-fixture.el" and d["severity"] == "error" and
           d["line"] is None and d["column"] is None and
           "End of file during parsing" in d["message"] for d in r["diagnostics"]), r
PY
cp syntax-fixture.saved lisp/report-fixture.el
run-report 1 ./makem.sh --json --emacs="$report_test_emacs" --no-compile batch
python3 - <<'PY'
import json
r = json.load(open("output.json"))
assert any((d["file"] or "").endswith("/lisp/report-fixture.el") and
           d["line"] == 4 and d["column"] == 1 for d in r["diagnostics"]), r
PY

# Multiple nested load frames do not identify an owner without guessing.
cat > lisp/report-fixture.el <<'ELISP'
(require 'report-untracked)
(defun report-fixture-add (value) (1+ value))
(provide 'report-fixture)
ELISP
cat > lisp/report-untracked.el <<'ELISP'
;;; Untracked dependency syntax fixture.
(defun report-untracked-function () t)
(provide 'report-untracked)
)
ELISP
run-report 1 ./makem.sh --json --emacs="$report_test_emacs" --no-compile batch
python3 - <<'PY'
import json
r = json.load(open("output.json"))
syntax = [d for d in r["diagnostics"] if "Invalid read syntax:" in d["message"]]
assert syntax and all(d["file"] is None and d["line"] is None for d in syntax), r
PY

# Restore a loadable source and prove failed ERT results survive JSON escaping.
cat > lisp/report-fixture.el <<'ELISP'
(defun report-fixture-add (value) (1+ value))
(provide 'report-fixture)
ELISP
cat >> test/report-fixture-tests.el <<'ELISP'
(ert-deftest report-fixture-intentional-failure ()
  (should (equal "quote\" newline\n雪" "different")))
ELISP
run-report 1 ./makem.sh --json --emacs="$report_test_emacs" --no-compile test-ert
python3 - <<'PY'
import json
r = json.load(open("output.json"))
assert any(c.get("tests", {}).get("unexpected") == 1 for c in r["commands"]), r
assert any("report-fixture-intentional-failure" in c["output"] for c in r["commands"])
assert r["tasks"][-1]["status"] == "error"
assert r["next_actions"]
located = [d for d in r["diagnostics"] if d["file"] == "test/report-fixture-tests.el"]
assert any(d["line"] == 7 and "report-fixture-intentional-failure" in d["message"]
           for d in located), r
PY

# Human diagnostics are plain when redirected and NO_COLOR is presence-based.
human_status=0
NO_COLOR= ./makem.sh --emacs="$report_test_emacs" --no-compile test-ert > human.out 2> human.err || human_status=$?
test "$human_status" != 0
test ! -s human.out
python3 - <<'PY'
assert "\x1b[" not in open("human.err").read()
assert "report-fixture-intentional-failure" in open("human.err").read()
PY

# Cancellation produces one final report and stops the real child Emacs.
./makem.sh --json --emacs="$report_test_emacs" --no-compile batch -- --eval '(progn (princ "ready") (sleep-for 30))' > signal.json 2> signal.err &
report_test_pid=$!
sleep 2
kill -TERM "$report_test_pid"
signal_status=0
wait "$report_test_pid" || signal_status=$?
test "$signal_status" == 143
python3 - <<'PY'
import json
import os
r = json.load(open("signal.json"))
assert r["exit_code"] == 143 and r["exit_kind"] == "terminated", r
assert any("interrupted" in d["message"] for d in r["diagnostics"])
assert r["commands"][-1]["exit_code"] == 143
child = r["commands"][-1]["pid"]
assert child is not None
try:
    os.kill(child, 0)
except ProcessLookupError:
    pass
else:
    raise AssertionError(f"Cancelled makem left child {child} running")
PY
printf 'makem JSON contract: all real-runner checks passed\n'
