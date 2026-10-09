import concurrent.futures
import datetime
import json
import pathlib
import re
import subprocess
import time

OUT = pathlib.Path(__file__).resolve().parent
CONTAINERS = ["ogent-fixes", "ogent-fixes-29"]
BASE = ["emacs", "-Q", "--batch", "-L", "/work/lisp", "-L", "/work/lisp/ui",
        "-L", "/work/test", "-L", "/work/test/ui", "-l", "/work/test/ogent-test-helper.el"]
SOURCE = '(progn (load "/work/lisp/ogent-agent.el" nil t t) (load "/work/lisp/ogent-tool-results.el" nil t t))'


def run(container):
    versions = {}
    for label, argv in [("emacs", ["emacs", "--version"]),
                        ("ripgrep", ["/tmp/ogent-test-rg", "--version"])]:
        command = ["docker", "exec", container, *argv]
        result = subprocess.run(command, capture_output=True, text=True, timeout=20)
        versions[label] = {"argv": command, "exit": result.returncode,
                           "stdout": result.stdout, "stderr": result.stderr}
        assert result.returncode == 0
    (OUT / (container + "-versions.json")).write_text(json.dumps(versions, indent=2) + "\n")
    records = []
    for label, tail in [
        ("sdk", ["--eval", SOURCE, "-l", "/work/test/ogent-agent-execution-tests.el",
                 "--eval", '(ert-run-tests-batch-and-exit "^ogent-agent-execution-")']),
        ("compiled-unicode", ["-l", "/work/agent_ergonomics_audit/audit/evidence/pass_3/review_round11/compiled-unicode-probe.el"]),
    ]:
        command = ["docker", "exec", "-w", "/work", "-e",
                   "OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg", container, *BASE, *tail]
        started = datetime.datetime.now(datetime.timezone.utc).isoformat()
        clock = time.monotonic()
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        elapsed = time.monotonic() - clock
        stem = container + "-" + label
        (OUT / (stem + ".stdout")).write_text(result.stdout)
        (OUT / (stem + ".stderr")).write_text(result.stderr)
        matches = re.findall(r"Ran (\d+) tests, (\d+) results as expected, (\d+) unexpected(?:, (\d+) skipped)?",
                             result.stdout + result.stderr)
        counts = None
        if matches:
            selected, expected, unexpected, skipped = matches[-1]
            counts = dict(selected=int(selected), expected=int(expected),
                          unexpected=int(unexpected), skipped=int(skipped or 0))
        record = {"container": container, "label": label, "argv": command,
                  "started": started, "elapsed_seconds": elapsed,
                  "exit": result.returncode, "counts": counts}
        (OUT / (stem + ".json")).write_text(json.dumps(record, indent=2) + "\n")
        print(json.dumps(record), flush=True)
        records.append(record)
    return records


if __name__ == "__main__":
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        records = sum(list(pool.map(run, CONTAINERS)), [])
    (OUT / "bounded_runs.json").write_text(json.dumps(records, indent=2) + "\n")
    assert all(record["exit"] == 0 and record["counts"] is not None
               and record["counts"]["unexpected"] == 0 and record["counts"]["skipped"] == 0
               for record in records), "Inspect preserved run transcripts"
