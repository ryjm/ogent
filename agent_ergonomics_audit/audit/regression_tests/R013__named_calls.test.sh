#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
exec bash "$root/tools/run-ert.sh" 'ogent-agent-execution-' test/ogent-agent-execution-tests.el
