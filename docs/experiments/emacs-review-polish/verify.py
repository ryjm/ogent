"""Archive executed local checks; refuse incomplete or failing evidence."""
import datetime
import gzip
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
PREFIX = Path(sys.argv[1] if len(sys.argv) > 1 else "/workspace/ogent-polish-")
OUT = Path(__file__).resolve().parent / "verification"
OUT.mkdir(exist_ok=True)


def fingerprint():
    paths = subprocess.check_output(["git", "ls-files", "lisp", "test", "makem.sh", "Makefile"], cwd=REPO, text=True).splitlines()
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(path.encode() + b"\0" + (REPO / path).read_bytes() + b"\0")
    return digest.hexdigest()


def archive(name, data):
    (OUT / (name + ".gz")).write_bytes(gzip.compress(data, mtime=0))


def main():
    results = []
    for name in ["suite30", "suite29", "current30", "current29", "minimum30", "minimum29"]:
        path = Path(str(PREFIX) + name + ".log")
        data = path.read_bytes()
        log = data.decode()
        matches = re.findall(r"Ran (\d+) tests, (\d+) results as expected, (\d+) unexpected, (\d+) skipped", log)
        if not matches:
            raise RuntimeError(f"{name}: incomplete test run")
        total, expected, unexpected, skipped = map(int, matches[-1])
        if unexpected or total != expected + skipped:
            raise RuntimeError(f"{name}: failing tests")
        isolation = "STORE-INTEGRITY: clean - no real-store drift" in log
        if name.startswith("suite") and not isolation:
            raise RuntimeError(f"{name}: missing store-integrity result")
        dependencies = re.findall(r"Offline dependencies: (.+)", log)
        results.append({"name": name, "total": total, "expected": expected, "unexpected": unexpected,
                        "skipped": skipped, "store_integrity": "clean" if isolation else "not this command",
                        "dependencies": dependencies[-1] if dependencies else "full suite with test helper",
                        "sha256": hashlib.sha256(data).hexdigest()})
        archive(name + ".log", data)
    data = Path(str(PREFIX) + "lint.json").read_bytes()
    lint = json.loads(data)
    if lint["status"] != "success" or lint["exit_code"]:
        raise RuntimeError("Lint did not pass")
    archive("lint.json", data)
    for name in ["keyboard-proof", "terminal-proof", "plain-proof", "early-evil-proof"]:
        proof = json.loads((OUT.parent / (name + ".json")).read_text())
        if proof["provider_requests"] or proof["actual_owned_cli_runs"] != 2 or len(proof["checks"]) != 18:
            raise RuntimeError(f"{name}: incomplete native key evidence")
    capture = json.loads((OUT.parent / "after-captures.json").read_text())
    source = fingerprint()
    if capture["source_fingerprint"] != source or capture["completed_fingerprint"] != source:
        raise RuntimeError("Native captures do not match the source under verification")
    for manifest in [capture, json.loads((OUT.parent / "before-captures.json").read_text())]:
        for shot in manifest["screenshots"]:
            if hashlib.sha256((REPO / shot["file"]).read_bytes()).hexdigest() != shot["sha256"]:
                raise RuntimeError(f"Image changed after capture: {shot['file']}")
    summary = {"recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "source_fingerprint": source, "fingerprint_paths": "git ls-files lisp test makem.sh Makefile",
               "provider_requests": False, "runs": results,
               "lint": {"status": lint["status"], "tasks": lint["tasks"], "sha256": hashlib.sha256(data).hexdigest()},
               "native_ui": {"emacs": "30.1", "gui_checks": 18, "terminal_ascii_checks": 18, "plain_terminal_checks": 18, "early_evil_checks": 18, "screenshots": len(capture["screenshots"])}}
    (OUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("Archived six passing test runs, strict lint, and native workflow evidence")


if __name__ == "__main__":
    main()
