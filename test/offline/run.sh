#!/usr/bin/env bash
# Run actual-dependency workflows with deterministic local fixtures.
set -euo pipefail
case "${1:-}" in
  -h|--help)
    printf '%s\n' 'Usage: OGENT_ELPA_DIR=/path/to/elpa make offline-test' \
      'Optional: OGENT_GPTEL_DIR=/path/to/gptel, EMACS=/path/to/emacs.' \
      'Runs local fixtures only; no provider login or requests.' \
      'Exit 0: tests passed; nonzero: prerequisite, fixture, or test failure.'
    exit 0 ;;
  '') ;;
  *) printf '%s\n' 'Unexpected argument; run test/offline/run.sh --help' >&2; exit 1 ;;
esac
if [ -z "${OGENT_ELPA_DIR:-}" ] || [ ! -d "$OGENT_ELPA_DIR" ]; then
  printf '%s\n' 'Set OGENT_ELPA_DIR=/path/to/installed/elpa, then run make offline-test.' >&2
  exit 1
fi
if [ -n "${OGENT_GPTEL_DIR:-}" ] && [ ! -d "$OGENT_GPTEL_DIR" ]; then
  printf '%s\n' 'OGENT_GPTEL_DIR must name an existing gptel source directory; omit it to use ELPA.' >&2
  exit 1
fi
for executable in "${EMACS:-emacs}" python3 timeout gzip; do
  if ! command -v "$executable" >/dev/null 2>&1; then
    printf 'Missing executable %s; install it or select an existing EMACS path.\n' "$executable" >&2
    exit 1
  fi
done
cd "$(dirname "$0")/../.."
fixture_root=$(mktemp -d)
cleanup() {
  kill "$fixture_pid" 2>/dev/null || true
  wait "$fixture_pid" 2>/dev/null || true
  rm -rf "$fixture_root"
}
python3 test/offline/http-fixture.py "$fixture_root" &
fixture_pid=$!
trap cleanup EXIT INT TERM
for attempt in {1..100}; do
  [ -s "$fixture_root/port" ] && break
  sleep .02
done
export OGENT_OFFLINE_FIXTURE="$fixture_root"
export NO_PROXY=127.0.0.1,localhost
export no_proxy="$NO_PROXY"
lisp_dir=$("${EMACS:-emacs}" -Q --batch --eval '(princ lisp-directory)')
if [ -f "$lisp_dir/jka-compr.el.gz" ]; then
  gzip -dc "$lisp_dir/jka-compr.el.gz" > "$fixture_root/jka-compr.el"
elif [ -f "$lisp_dir/jka-compr.el" ]; then
  cp "$lisp_dir/jka-compr.el" "$fixture_root/jka-compr.el"
fi
timeout 180 "${EMACS:-emacs}" -Q --batch -L "$fixture_root" -l jka-compr \
  -L lisp -L lisp/ui -L test -L test/ui \
  -l test/offline/boot.el.in -l test/offline/workflows.el.in \
  --eval "(ert-run-tests-batch-and-exit '(or \"ogent-offline-\" \"ogent-armory-\" \"ogent-workbench-\" \"ogent-task-\")))"
