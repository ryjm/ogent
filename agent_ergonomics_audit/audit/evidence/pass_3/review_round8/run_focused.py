import json
import pathlib
import re
import subprocess
import sys
import time

here = pathlib.Path(__file__).parent
container = sys.argv[1]
argv = ["docker", "exec", "-e", "OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg",
        container, "emacs", "-Q", "--batch", "-L", "/work/lisp", "-L", "/work/lisp/ui",
        "-L", "/work/test", "-L", "/work/test/ui", "-l", "/work/test/ogent-test-helper.el",
        "-l", "/work/agent_ergonomics_audit/audit/evidence/pass_3/review_round8/focused.el"]
started = time.time()
result = subprocess.run(argv, capture_output=True, text=True)
(here / (container + ".stdout")).write_text(result.stdout)
(here / (container + ".stderr")).write_text(result.stderr)
summary = re.search(r"Ran (\d+) tests?, (\d+) results as expected, (\d+) unexpected(?:, (\d+) skipped)?", result.stderr)
report = {"argv": argv, "exit_code": result.returncode, "elapsed_seconds": time.time() - started,
          "summary": dict(zip(["selected", "expected", "unexpected", "skipped"],
                               [int(x or 0) for x in summary.groups()])) if summary else None}
(here / (container + ".json")).write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report))
sys.exit(result.returncode)
