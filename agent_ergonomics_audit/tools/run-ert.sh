#!/usr/bin/env bash
# Replay an ergonomics regression selector with current or baseline sources.
set -euo pipefail
case "${1:-}" in
  -h|--help)
    printf '%s\n' 'Usage: run-ert.sh ERT-SELECTOR' \
      'Set EMACS for the executable; OGENT_AUDIT_SOURCE for baseline source root.' \
      'Exit: 0 all selected tests pass; nonzero means a regression or environment failure.'
    exit 0 ;;
  '') printf '%s\n' 'Missing ERT selector; run run-ert.sh --help' >&2; exit 1 ;;
esac
audit_root=$(cd "$(dirname "$0")/.." && pwd)
repo_root=$(cd "$audit_root/.." && pwd)
export OGENT_AUDIT_SELECTOR="$1"
"${EMACS:-emacs}" -Q --batch \
  -L "$repo_root/lisp" -L "$repo_root/lisp/ui" \
  -L "$repo_root/test" -L "$repo_root/test/ui" \
  -l "$repo_root/test/ogent-test-helper.el" \
  --eval '(when-let ((root (getenv "OGENT_AUDIT_SOURCE")))
            (add-to-list (quote load-path) (expand-file-name "lisp" root))
            (add-to-list (quote load-path) (expand-file-name "lisp/ui" root)))' \
  -l "$repo_root/test/ogent-agent-ergonomics-tests.el" \
  --eval '(ert-run-tests-batch-and-exit (getenv "OGENT_AUDIT_SELECTOR"))'
