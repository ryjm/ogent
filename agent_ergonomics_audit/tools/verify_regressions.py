"""Replay each improvement against archived baseline and current Emacs sources."""
import argparse
import datetime
import json
import re
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(
        description="Verify baseline failures and post-change passes; exit 1 on invalid proof.")
    parser.add_argument("--container", help="Existing Docker Emacs container mounting the repo at /work")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    audit = repo / "agent_ergonomics_audit/audit"
    out = audit / "verification/regressions"
    out.mkdir(parents=True, exist_ok=True)
    baseline = "72016bb66928a20a49238266645abde583fa595d"
    current = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    rows = []
    for test in sorted((audit / "regression_tests").glob("R-*.test.sh")):
        row = {"recommendation_id": test.name.split("__")[0], "test_path": str(test.relative_to(audit.parent)),
               "baseline_sha": baseline, "post_sha": current}
        for stage in ("baseline", "post"):
            timeout_seconds = 8 if stage == "baseline" and row["recommendation_id"] == "R-005" else 30
            source = audit / "partial/baseline"
            rel = test.relative_to(repo)
            if args.container:
                command = ["docker", "exec"]
                if stage == "baseline":
                    command += ["-e", "OGENT_AUDIT_SOURCE=/work/agent_ergonomics_audit/audit/partial/baseline"]
                command += [args.container, "timeout", str(timeout_seconds), "bash", str(Path("/work") / rel)]
            else:
                import os
                command = ["timeout", str(timeout_seconds), "bash", str(test)]
                env = dict(os.environ)
                if stage == "baseline":
                    env["OGENT_AUDIT_SOURCE"] = str(source)
            result = subprocess.run(command, cwd=repo, capture_output=True, text=True,
                                    **({} if args.container else {"env": env}))
            log = result.stdout + result.stderr
            log_file = out / f"{row['recommendation_id']}-{stage}.log"
            log_file.write_text(log)
            summaries = re.findall(r"Ran .*tests.*|\s+(?:FAILED|passed)\s+\d+/\d+.*", log)
            row[stage] = {"argv": command, "exit_code": result.returncode,
                          "log": str(log_file.relative_to(audit.parent)),
                          "summary": summaries[-10:], "timed_out": result.returncode == 124,
                          "timeout_seconds": timeout_seconds}
        row["verified"] = row["baseline"]["exit_code"] != 0 and row["post"]["exit_code"] == 0
        rows.append(row)
        print(f"{row['recommendation_id']}: baseline={row['baseline']['exit_code']} post={row['post']['exit_code']}")
    proof = {"recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "records": rows,
             "all_verified": all(row["verified"] for row in rows)}
    (audit / "verification/regression_proof.json").write_text(json.dumps(proof, indent=2) + "\n")
    raise SystemExit(0 if proof["all_verified"] else 1)


if __name__ == "__main__":
    main()
