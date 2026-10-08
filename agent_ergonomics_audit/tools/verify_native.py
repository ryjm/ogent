"""Record real exit codes and transcripts for the final provider-free checks."""
import concurrent.futures
import datetime
import json
import re
import subprocess
from pathlib import Path


def main():
    repo = Path(__file__).resolve().parents[2]
    out = repo / "agent_ergonomics_audit/audit/verification/native"
    out.mkdir(parents=True, exist_ok=True)
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()

    def run(label, argv):
        started = datetime.datetime.now(datetime.timezone.utc)
        result = subprocess.run(argv, cwd=repo, capture_output=True, text=True)
        for stream in ("stdout", "stderr"):
            (out / f"{label}.{stream}.log").write_text(getattr(result, stream))
        summary = re.findall(r"^.*(?:Ran \d+ tests|STORE-INTEGRITY:|Offline dependencies:).*$",
                             result.stdout + result.stderr, re.MULTILINE)
        record = {"check": label, "argv": argv, "exit_code": result.returncode,
                  "source_sha": sha, "started_at": started.isoformat(),
                  "completed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  "summary": summary,
                  "stdout": f"audit/verification/native/{label}.stdout.log",
                  "stderr": f"audit/verification/native/{label}.stderr.log"}
        (out / f"{label}.json").write_text(json.dumps(record, indent=2) + "\n")
        print(f"{label}: exit={result.returncode} {'; '.join(summary)}", flush=True)
        return record

    def version_checks(version, container, elpa):
        # Serialize checks within each runtime: makem can rewrite shared bytecode.
        checks = []
        if version == "30":
            for target in ("lint", "test"):
                checks.append(run(f"emacs{version}-{target}",
                                  ["docker", "exec", "-w", "/work", container,
                                   "make", target, "sandbox=/tmp/ogent-fixdeps"]))
        checks.append(run(f"emacs{version}-store-isolation",
                          ["docker", "exec", "-w", "/work", container,
                           "make", "test-isolation"]))
        for dependency in ("current", "minimum"):
            command = ["docker", "exec", "-w", "/work", "-e", f"OGENT_ELPA_DIR={elpa}"]
            if dependency == "minimum":
                command += ["-e", "OGENT_GPTEL_DIR=/tmp/gptel-minimum"]
            command += [container, "make", "offline-test"]
            checks.append(run(f"emacs{version}-offline-{dependency}", command))
        return checks

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(version_checks, "30", "ogent-fixes", "/tmp/ogent-fixdeps/30.2/elpa"),
                   pool.submit(version_checks, "29", "ogent-fixes-29", "/tmp/ogent-ergonomics-elpa")]
        records = [record for future in futures for record in future.result()]
    proof = {"source_sha": sha, "provider_requests": False, "checks": records,
             "all_passed": all(record["exit_code"] == 0 for record in records)}
    (out.parent / "native_checks.json").write_text(json.dumps(proof, indent=2) + "\n")
    raise SystemExit(0 if proof["all_passed"] else 1)


if __name__ == "__main__":
    main()
