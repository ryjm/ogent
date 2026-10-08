#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in -h|--help) printf "%s\n" "Replay R-011 via ERT; exit 0 on success, nonzero on failure."; exit 0;; esac
exec bash "$(dirname "$0")/../../tools/run-ert.sh" "^ogent-agent-ergonomics-make-contract"
