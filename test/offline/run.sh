#!/usr/bin/env bash
# Run actual-dependency workflows with deterministic local fixtures.
set -euo pipefail
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
  --eval "(ert-run-tests-batch-and-exit '(or \"ogent-offline-\" \"ogent-armory-\")))"
