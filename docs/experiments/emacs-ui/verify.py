"""Record native checks on an unchanged source tree without provider calls."""
import concurrent.futures
import datetime
import gzip
import hashlib
import json
import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
OUT = REPO / "docs/experiments/emacs-ui/verification"
OUT.mkdir(parents=True, exist_ok=True)


def write_log(label, stream, content):
    """Retain exact tool output, compressing nonempty reports for the repository."""
    data = content.encode()
    path = OUT / f"{label}.{stream}.log"
    for old in (path, path.with_suffix(".log.gz")):
        old.unlink(missing_ok=True)
    if data:
        path = path.with_suffix(".log.gz")
        path.write_bytes(gzip.compress(data, mtime=0))
    else:
        path.write_bytes(data)
    return {"file": str(path.relative_to(REPO)), "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest()}


def fingerprint():
    paths = subprocess.check_output(["git", "ls-files", "-z", "lisp", "test", "makem.sh", "Makefile"], cwd=REPO).split(b"\0")
    digest = hashlib.sha256()
    for path in sorted(filter(None, paths)):
        digest.update(path + b"\0" + (REPO / path.decode()).read_bytes() + b"\0")
    return digest.hexdigest()


def run(label, argv):
    started = datetime.datetime.now(datetime.timezone.utc)
    result = subprocess.run(argv, cwd=REPO, capture_output=True, text=True)
    logs = {stream: write_log(label, stream, getattr(result, stream))
            for stream in ("stdout", "stderr")}
    summary = re.findall(r"^.*(?:Ran \d+ tests|STORE-INTEGRITY:|Offline dependencies:).*$", (result.stderr if "format=json" in argv else result.stdout + result.stderr), re.MULTILINE)
    if "format=json" in argv:
        report = json.loads(result.stdout)
        if report["status"] != "success" or report["exit_code"] != 0:
            result.returncode = result.returncode or 1
        summary.append(f"Actual makem JSON: {report['status']}; exit={report['exit_code']}")
        for command in report.get("commands", []):
            if "tests" in command:
                summary.append("Actual ERT totals: " + json.dumps(command["tests"], sort_keys=True))
    record = {"check": label, "argv": argv, "exit_code": result.returncode,
              "started_at": started.isoformat(),
              "completed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "summary": summary, "logs": logs}
    (OUT / f"{label}.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"{label}: exit={result.returncode}; {'; '.join(summary)}", flush=True)
    return record


def main():
    initial = fingerprint()
    # Reuse the just-completed strict Make lint on this frozen source.
    lint = json.loads(Path("/workspace/ogent-ui-lint.json").read_text())
    if lint["exit_code"] != 0 or lint["status"] != "success":
        raise RuntimeError("Strict lint has not passed")
    lint_logs = {stream: write_log("emacs30-lint", stream, Path(path).read_text())
                 for stream, path in [("stdout", "/workspace/ogent-ui-lint.json"),
                                      ("stderr", "/workspace/ogent-ui-lint.log")]}
    records = [{"check": "emacs30-lint", "exit_code": 0,
                "argv": ["make", "lint", "sandbox=/tmp/ogent-fixdeps", "format=json"],
                "summary": ["All strict repository lints passed; actual Make JSON retained"],
                "logs": lint_logs}]

    def checks(version, container, elpa):
        completed = []
        base = ["docker", "exec", "-w", "/work", "-e", "OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg", container]
        if version == "30":
            completed.append(run("emacs30-test", base + ["make", "test", "sandbox=/tmp/ogent-fixdeps", "format=json",
                                  "MAKEM=./makem.sh --emacs=emacs --json --no-compile"]))
        completed.append(run(f"emacs{version}-store-isolation", base + ["make", "test-isolation"]))
        for dependency in ("current", "minimum"):
            command = ["docker", "exec", "-w", "/work", "-e", f"OGENT_ELPA_DIR={elpa}",
                       "-e", "OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg"]
            if dependency == "minimum":
                command += ["-e", "OGENT_GPTEL_DIR=/tmp/gptel-minimum"]
            completed.append(run(f"emacs{version}-offline-{dependency}", command + [container, "make", "offline-test"]))
        return completed

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(checks, "30", "ogent-fixes", "/tmp/ogent-fixdeps/30.2/elpa"),
                   pool.submit(checks, "29", "ogent-fixes-29", "/tmp/ogent-ergonomics-elpa")]
        records.extend(record for future in futures for record in future.result())
    final = fingerprint()
    proof = {"source_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
             "source_state": "working tree verified by source fingerprint",
             "source_fingerprint": initial, "completed_fingerprint": final,
             "provider_requests": False, "checks": records}
    (OUT / "summary.json").write_text(json.dumps(proof, indent=2) + "\n")
    if final != initial or any(record["exit_code"] for record in records):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
