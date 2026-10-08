#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
bash "$root/tools/run-ert.sh" 'ogent-tool-process-' test/ogent-tool-process-tests.el
exec bash "$root/tools/run-ert.sh" 'ogent-agent-execution-process-' test/ogent-agent-execution-tests.el
