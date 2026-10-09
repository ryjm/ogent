"""Record real exit codes and transcripts for the final provider-free checks."""
import concurrent.futures
import argparse
import datetime
import hashlib
import json
import re
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pass-number", type=int)
    parser.add_argument("--json-build", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    folder = f"pass_{args.pass_number}/native" if args.pass_number else "native"
    out = repo / "agent_ergonomics_audit/audit/verification" / folder
    out.mkdir(parents=True, exist_ok=True)
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()

    def source_fingerprint():
        paths = subprocess.check_output(["git", "ls-files", "-z", "lisp", "test", "makem.sh", "Makefile"], cwd=repo).split(b"\0")
        digest = hashlib.sha256()
        for path in sorted(p for p in paths if p):
            digest.update(path + b"\0" + (repo / path.decode()).read_bytes() + b"\0")
        return digest.hexdigest()

    fingerprint = source_fingerprint()

    def run(label, argv):
        started = datetime.datetime.now(datetime.timezone.utc)
        result = subprocess.run(argv, cwd=repo, capture_output=True, text=True)
        for stream in ("stdout", "stderr"):
            (out / f"{label}.{stream}.log").write_text(getattr(result, stream))
        machine_report = "format=json" in argv
        summary_text = result.stderr if machine_report else result.stdout + result.stderr
        summary = re.findall(r"^.*(?:Ran \d+ tests|STORE-INTEGRITY:|Offline dependencies:).*$",
                             summary_text, re.MULTILINE)
        if machine_report:
            try:
                report = json.loads(result.stdout)
                summary.append(f"Actual makem JSON: {report['status']}; exit={report['exit_code']}")
                for command in report.get("commands", []):
                    if "tests" in command:
                        summary.append(f"ERT: {command['tests']}")
                if report["exit_code"] != result.returncode:
                    summary.append("GNU Make returns its own failure exit; helper code retained in JSON")
            except (ValueError, KeyError):
                result.returncode = result.returncode or 1
                summary.append("Machine report failed JSON/schema validation")
        record = {"check": label, "argv": argv, "exit_code": result.returncode,
                  "source_sha": sha, "started_at": started.isoformat(),
                  "completed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  "summary": summary,
                  "stdout": f"audit/verification/{folder}/{label}.stdout.log",
                  "stderr": f"audit/verification/{folder}/{label}.stderr.log"}
        (out / f"{label}.json").write_text(json.dumps(record, indent=2) + "\n")
        print(f"{label}: exit={result.returncode} {'; '.join(summary)}", flush=True)
        return record

    def version_checks(version, container, elpa):
        # Serialize checks within each runtime: makem can rewrite shared bytecode.
        checks = []
        if version == "30":
            for target in ("lint", "test"):
                command = ["docker", "exec", "-w", "/work", "-e",
                           "OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg", container,
                           "make", target, "sandbox=/tmp/ogent-fixdeps"]
                if args.json_build:
                    command.append("format=json")
                    if target == "test" and checks[-1]["exit_code"] == 0:
                        # Full strict lint has just compiled the same source.
                        # Run the actual Make test target without duplicating
                        # that compilation; its complete ERT selection remains.
                        command.append("MAKEM=./makem.sh --emacs=emacs --json --no-compile")
                checks.append(run(f"emacs{version}-{target}", command))
        checks.append(run(f"emacs{version}-store-isolation",
                          ["docker", "exec", "-w", "/work", "-e",
                           "OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg", container,
                           "make", "test-isolation"]))
        for dependency in ("current", "minimum"):
            command = ["docker", "exec", "-w", "/work", "-e", f"OGENT_ELPA_DIR={elpa}",
                       "-e", "OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg"]
            if dependency == "minimum":
                command += ["-e", "OGENT_GPTEL_DIR=/tmp/gptel-minimum"]
            command += [container, "make", "offline-test"]
            checks.append(run(f"emacs{version}-offline-{dependency}", command))
        return checks

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(version_checks, "30", "ogent-fixes", "/tmp/ogent-fixdeps/30.2/elpa"),
                   pool.submit(version_checks, "29", "ogent-fixes-29", "/tmp/ogent-ergonomics-elpa")]
        records = [record for future in futures for record in future.result()]
    completed_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    completed_fingerprint = source_fingerprint()
    proof = {"source_sha": sha, "completed_sha": completed_sha,
             "source_fingerprint": fingerprint, "completed_fingerprint": completed_fingerprint,
             "provider_requests": False, "checks": records,
             "all_passed": sha == completed_sha and fingerprint == completed_fingerprint
             and all(record["exit_code"] == 0 for record in records)}
    (out.parent / "native_checks.json").write_text(json.dumps(proof, indent=2) + "\n")
    raise SystemExit(0 if proof["all_passed"] else 1)


if __name__ == "__main__":
    main()
