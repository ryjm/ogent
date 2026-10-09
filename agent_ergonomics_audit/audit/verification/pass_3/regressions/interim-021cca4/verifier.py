#!/usr/bin/env python3
"""Record genuine pass-3 baseline failures and current wrapper passes.

Replay unchanged wrappers against an archive verified byte-for-byte with Git.
The current tests remain current in both stages.  No source failure stubs are
installed.  Pass 1's verification/regression_proof.json is never overwritten.
"""

import argparse
import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import time


BASELINE = "b3caf9300c7336ef812ed061158f851c5a47ccf7"
TIMEOUT = 90
IDS = [f"R{number:03}" for number in range(13, 24)]
ERT_START = re.compile(r"^Running (\d+) tests", re.M)
ERT_END = re.compile(r"^Ran (\d+) tests, (\d+) results as expected, (\d+) unexpected", re.M)
ERT_RESULT = re.compile(r"^\s*(passed|FAILED|skipped)\s+(\d+)/(\d+)\s+(\S+)", re.M)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git(repo, *arguments):
    return subprocess.check_output(["git", *arguments], cwd=repo)


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def source_snapshot(repo, audit, out, stage):
    """Verify the archive, then record the exact source bytes used for replay."""
    source = audit / "partial/baseline_pass_3" if stage == "baseline" else repo
    revision = BASELINE if stage == "baseline" else git(repo, "rev-parse", "HEAD").decode().strip()
    if stage == "baseline":
        # Extract the real helper, rather than inventing a baseline replacement.
        (source / "makem.sh").write_bytes(git(repo, "show", f"{BASELINE}:makem.sh"))
        archive = git(repo, "archive", BASELINE, "lisp", "makem.sh")
        with tarfile.open(fileobj=io.BytesIO(archive)) as stream:
            archived = {member.name: stream.extractfile(member).read()
                        for member in stream.getmembers() if member.isfile()}
        actual = {str(path.relative_to(source)): path.read_bytes()
                  for path in (source / "lisp").rglob("*") if path.is_file()}
        actual["makem.sh"] = (source / "makem.sh").read_bytes()
        if actual != archived:
            different = sorted(name for name in set(actual) | set(archived)
                               if actual.get(name) != archived.get(name))
            raise RuntimeError(f"Baseline archive differs from {BASELINE}: {different}")
        clean = True
    else:
        actual = {str(path.relative_to(source)): path.read_bytes()
                  for path in (source / "lisp").rglob("*.el")}
        actual["makem.sh"] = (source / "makem.sh").read_bytes()
        actual["Makefile"] = (source / "Makefile").read_bytes()
        clean = not git(repo, "status", "--porcelain", "--", "lisp", "makem.sh", "Makefile").strip()
    hashes = {name: sha256(data) for name, data in sorted(actual.items())}
    fingerprint = sha256(json.dumps(hashes, sort_keys=True).encode())
    snapshot = {"revision": revision, "source_root": str(source),
                "source_root_in_container": "/work/" + str(source.relative_to(repo))
                if source != repo else "/work",
                "verified_git_archive": stage == "baseline",
                "tracked_source_clean": clean, "source_fingerprint_sha256": fingerprint,
                "files_sha256": hashes}
    path = out / f"{stage}-source.json"
    save_json(path, snapshot)
    return {"revision": revision, "source_root": snapshot["source_root"],
            "source_root_in_container": snapshot["source_root_in_container"],
            "tracked_source_clean": clean, "verified_git_archive": stage == "baseline",
            "source_fingerprint_sha256": fingerprint,
            "manifest": str(path.relative_to(repo)), "manifest_sha256": sha256(path.read_bytes())}


def wrapper_contract(repo, wrapper):
    text = wrapper.read_text()
    runs = []
    for selector, test_file in re.findall(r'run-ert\.sh"\s+\x27([^\x27]+)\x27\s+(\S+)', text):
        names = re.findall(r"^\(ert-deftest\s+(\S+)", (repo / test_file).read_text(), re.M)
        selected = sorted(name for name in names if re.search(selector, name))
        if not selected:
            raise RuntimeError(f"Empty selector {selector}: {wrapper}")
        runs.append({"selector": selector, "test_file": test_file,
                     "expected_count": len(selected), "expected_names": selected})
    if wrapper.name.startswith("R023__"):
        fixture = (repo / "test/makem-report-tests.sh").read_text()
        reports = len(re.findall(r"^run-report\s", fixture, re.M))
        return {"kind": "shell_fixture", "test_file": "test/makem-report-tests.sh",
                "expected_report_invocations": reports,
                "expected_count": reports + 2,
                "count_unit": "real-runner cases (report calls, human failure, cancellation)"}
    if not runs:
        raise RuntimeError(f"No recognized test selector: {wrapper}")
    return {"kind": "ert", "runs": runs,
            "expected_count": sum(run["expected_count"] for run in runs), "count_unit": "ERT tests"}


def parse_ert(log, contract, stage):
    starts = list(ERT_START.finditer(log))
    endings = list(ERT_END.finditer(log))
    runs = []
    errors = []
    for index, start in enumerate(starts):
        boundary = starts[index + 1].start() if index + 1 < len(starts) else len(log)
        section = log[start.start():boundary]
        ending = ERT_END.search(section)
        results = [{"status": match[0], "index": int(match[1]),
                    "selected_total": int(match[2]), "name": match[3]}
                   for match in ERT_RESULT.findall(section)]
        record = {"selected": int(start.group(1)), "completed": len(results),
                  "expected": int(ending.group(2)) if ending else None,
                  "unexpected": int(ending.group(3)) if ending else None,
                  "skipped": sum(row["status"] == "skipped" for row in results),
                  "results": results, "summary": ending.group(0) if ending else None}
        expected = contract["runs"][index] if index < len(contract["runs"]) else None
        if (not expected or not ending or int(ending.group(1)) != record["selected"]
                or record["completed"] != record["selected"]
                or record["selected"] != expected["expected_count"]
                or sorted(row["name"] for row in results) != expected["expected_names"]
                or sorted(row["index"] for row in results) != list(range(1, record["selected"] + 1))):
            errors.append(f"ERT run {index + 1} lacks complete matching selected-test evidence")
        if stage == "current" and (record["unexpected"] != 0 or record["skipped"] != 0):
            errors.append(f"Current ERT run {index + 1} contains failures or skipped tests")
        runs.append(record)
    if not starts or len(endings) != len(starts):
        errors.append("No complete ERT runs, or mismatched start/end summaries")
    if stage == "current" and len(runs) != len(contract["runs"]):
        errors.append("Current wrapper did not execute every ERT selector")
    if stage == "baseline" and not any((run["unexpected"] or 0) > 0 for run in runs):
        errors.append("Baseline did not demonstrate an unexpected selected-test result")
    return {"selected_count": sum(run["selected"] for run in runs),
            "completed_count": sum(run["completed"] for run in runs),
            "executed_count": sum(run["completed"] - run["skipped"] for run in runs),
            "skipped_count": sum(run["skipped"] for run in runs),
            "unexpected_count": sum(run["unexpected"] or 0 for run in runs),
            "runs": runs, "unexecuted_selectors": contract["runs"][len(runs):],
            "evidence_errors": errors}


def parse_shell(log, contract, stage):
    reports = re.findall(r"^\+ run-report (.+)$", log, re.M)
    human = bool(re.search(r"^\+ ./makem\.sh --emacs=.* --no-compile test-ert$", log, re.M))
    cancellation = bool(re.search(r"^\+ ./makem\.sh --json --emacs=.* --no-compile batch -- --eval .*sleep-for 30", log, re.M))
    success = "makem JSON contract: all real-runner checks passed\n" in log
    failure = re.search(r"^Expected exit (\d+), got (\d+): (.+)$", log, re.M)
    count = len(reports) + int(human) + int(cancellation)
    errors = []
    if stage == "current" and (not success or count != contract["expected_count"]
                                or len(reports) != contract["expected_report_invocations"]):
        errors.append("Current fixture lacks every traced real-runner case and success marker")
    if stage == "baseline" and (not reports or not failure or success):
        errors.append("Baseline fixture lacks a traced real-runner assertion failure")
    return {"selected_count": count, "executed_count": count,
            "report_invocations": reports, "human_failure_case_executed": human,
            "cancellation_case_executed": cancellation, "fixture_success_marker": success,
            "first_failing_assertion": failure.group(0) if failure else None,
            "evidence_errors": errors}


def replay(repo, audit, out, wrapper, contract, stage, source, container, trace, process_test_rg,
           timeout_seconds):
    root = Path("/work") if container else repo
    overrides = {"MAKEM_UNDER_TEST": str(root / "agent_ergonomics_audit/audit/partial/baseline_pass_3/makem.sh")
                 if stage == "baseline" else str(root / "makem.sh")}
    if stage == "baseline":
        overrides["OGENT_AUDIT_SOURCE"] = str(root / "agent_ergonomics_audit/audit/partial/baseline_pass_3")
    if process_test_rg:
        overrides["OGENT_PROCESS_TEST_RG"] = process_test_rg
    if contract["kind"] == "shell_fixture":
        overrides["BASH_ENV"] = str(root / trace.relative_to(repo))
    argv = ["timeout", "--kill-after=5", str(timeout_seconds), "bash", str(root / wrapper.relative_to(repo))]
    env = dict(os.environ)
    for name in ("OGENT_AUDIT_SOURCE", "MAKEM_UNDER_TEST", "BASH_ENV"):
        env.pop(name, None)
    if container:
        argv = ["docker", "exec", container, "env", "-u", "OGENT_AUDIT_SOURCE",
                "-u", "MAKEM_UNDER_TEST", "-u", "BASH_ENV",
                *(f"{name}={setting}" for name, setting in overrides.items()), *argv]
    else:
        env.update(overrides)
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    clock = time.monotonic()
    path = out / f"{wrapper.name.split('__')[0]}-{stage}.log"
    try:
        with path.open("wb") as stream:
            process = subprocess.run(argv, cwd=repo, env=env, stdout=stream,
                                     stderr=subprocess.STDOUT, timeout=timeout_seconds + 20)
            exit_code = process.returncode
    except subprocess.TimeoutExpired:
        with path.open("ab") as stream:
            stream.write(b"\nRecorder host timeout; proof rejected.\n")
        exit_code = 124
    data = path.read_bytes()
    log = data.decode("utf-8", errors="replace")
    parsed = parse_ert(log, contract, stage) if contract["kind"] == "ert" else parse_shell(log, contract, stage)
    timeout = exit_code in (124, 137)
    errors = parsed["evidence_errors"]
    if timeout:
        errors.append("Timeout or forced kill cannot establish regression proof")
    if stage == "baseline" and exit_code == 0:
        errors.append("Baseline unexpectedly passed")
    if stage == "current" and exit_code != 0:
        errors.append(f"Current wrapper exited {exit_code}")
    if stage == "current" and not source["tracked_source_clean"]:
        errors.append("Current source differs from its recorded Git revision")
    return {"argv": argv, "environment_overrides": overrides, "started_at": started,
            "duration_seconds": round(time.monotonic() - clock, 3),
            "exit_code": exit_code, "timed_out": timeout, "timeout_seconds": timeout_seconds,
            "log": str(path.relative_to(repo)), "log_sha256": sha256(data),
            "source": source, **parsed, "proven": not errors}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", help="Existing Emacs container mounting this repository at /work")
    parser.add_argument("--stage", choices=("baseline", "current", "both"), default="both")
    parser.add_argument("--expected-current-sha", help="Reject current runs unless HEAD matches the source freeze")
    parser.add_argument("--process-test-rg", help="Actual portable rg binary for the optional process protocol tests")
    parser.add_argument("--large-baseline-timeout-seconds", type=int, choices=(90, 120, 150), default=90,
                        help="Bounded timeout for baseline selectors containing more than 40 tests")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    audit = repo / "agent_ergonomics_audit/audit"
    out = audit / "verification/pass_3/regressions"
    out.mkdir(parents=True, exist_ok=True)
    proof_path = out.parent / "regression_proof.json"
    proof = json.loads(proof_path.read_text()) if proof_path.exists() else {"records": []}
    existing = {row["recommendation_id"]: row for row in proof["records"]}
    verifier = {"path": str(Path(__file__).resolve().relative_to(repo)),
                "sha256": sha256(Path(__file__).read_bytes())}
    # An interrupted or rejected rerun must not leave a prior all_proven=true
    # record appearing to establish proof for a newly requested source freeze.
    proof.update(all_proven=False, status="verification_in_progress",
                 requested_current_revision=args.expected_current_sha, verifier=verifier)
    save_json(proof_path, proof)
    trace = out / "fixture_trace.sh"
    trace.write_text('# Recorder only: trace this fixture, never its actual makem child.\n'
                     'case "$0" in */test/makem-report-tests.sh) set -x ;; esac\n')
    wrappers = sorted((audit / "regression_tests").glob("R0[12][0-9]__*.test.sh"))
    if [path.name.split("__")[0] for path in wrappers] != IDS:
        raise RuntimeError("Expected exactly R013 through R023 wrappers")
    stages = ("baseline", "current") if args.stage == "both" else (args.stage,)
    tool_prefix = ["docker", "exec", args.container] if args.container else []
    runtime = {"emacs_version": subprocess.check_output(tool_prefix + ["emacs", "--version"],
                                                        text=True).splitlines()[0]}
    if args.process_test_rg:
        subprocess.check_call(tool_prefix + ["test", "-x", args.process_test_rg])
        runtime["process_test_rg"] = {"path": args.process_test_rg,
                                      "sha256": subprocess.check_output(
                                          tool_prefix + ["sha256sum", args.process_test_rg],
                                          text=True).split()[0],
                                      "version": subprocess.check_output(
                                          tool_prefix + [args.process_test_rg, "--version"],
                                          text=True).splitlines()[0]}
    save_json(out / "runtime.json", runtime)
    for stage in stages:
        if stage == "current" and args.expected_current_sha:
            actual = git(repo, "rev-parse", "HEAD").decode().strip()
            if actual != args.expected_current_sha:
                raise RuntimeError(f"Current HEAD {actual} differs from freeze {args.expected_current_sha}")
        source = source_snapshot(repo, audit, out, stage)
        for wrapper in wrappers:
            identifier = wrapper.name.split("__")[0]
            contract = wrapper_contract(repo, wrapper)
            input_files = [wrapper, repo / "agent_ergonomics_audit/tools/run-ert.sh",
                           repo / "test/ogent-test-helper.el"]
            if contract["kind"] == "ert":
                input_files += [repo / run["test_file"] for run in contract["runs"]]
            else:
                input_files += [repo / contract["test_file"], repo / "Makefile", trace]
            inputs = {str(path.relative_to(repo)): sha256(path.read_bytes()) for path in input_files}
            row = existing.setdefault(identifier, {"recommendation_id": identifier})
            previous = row.get("test_inputs_sha256")
            if previous and previous != inputs and stage == "current":
                raise RuntimeError(f"{identifier}: fixtures changed after baseline recording; rerun baseline")
            if previous and previous != inputs and stage == "baseline":
                row.pop("current", None)
            row.update(test_path=str(wrapper.relative_to(repo)), test_inputs_sha256=inputs,
                       contract=contract, baseline_revision=BASELINE)
            timeout_seconds = (args.large_baseline_timeout_seconds
                               if stage == "baseline" and contract["expected_count"] > 40 else TIMEOUT)
            row[stage] = replay(repo, audit, out, wrapper, contract, stage, source, args.container, trace,
                                args.process_test_rg, timeout_seconds)
            row[stage]["runtime"] = runtime
            if inputs != {str(path.relative_to(repo)): sha256(path.read_bytes()) for path in input_files}:
                row[stage]["evidence_errors"].append("Fixtures changed during wrapper replay")
                row[stage]["proven"] = False
            row["proven"] = all(row.get(part, {}).get("proven", False) for part in ("baseline", "current"))
            if identifier == "R013":
                row["coverage_note"] = "Broad execution selector overlaps R014-R022. It proves wrapper coverage, not causal unique per-change scoring."
            if identifier == "R018":
                row["coverage_note"] = "Wrapper runs process suite then execution integration suite under set -e. Baseline failure of the first suite short-circuits the second; current must execute both."
            save_json(out / f"{identifier}.json", row)
            print(f"{identifier} {stage}: exit={row[stage]['exit_code']} "
                  f"selected={row[stage]['selected_count']} executed={row[stage]['executed_count']} "
                  f"proven={row[stage]['proven']}", flush=True)
            if not row[stage]["proven"]:
                print(f"  Rejected: {row[stage]['evidence_errors']}", flush=True)
        after = source_snapshot(repo, audit, out, stage)
        if source["revision"] != after["revision"] or source["source_fingerprint_sha256"] != after["source_fingerprint_sha256"]:
            raise RuntimeError(f"{stage} sources changed during verification")
    records = [existing[identifier] for identifier in IDS]
    proof = {"recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
             "status": "complete", "verifier": verifier,
             "baseline_revision": BASELINE,
             "current_revision": records[0].get("current", {}).get("source", {}).get("revision"),
             "container": args.container, "timeout_seconds": TIMEOUT,
             "large_baseline_timeout_seconds": args.large_baseline_timeout_seconds,
             "count_note": "ERT tests and R023 real-runner shell cases are separate count units.",
             "attribution_note": "Selectors overlap; wrapper proofs do not assign unique causal uplift to individual recommendations.",
             "records": records, "all_proven": all(row["proven"] for row in records)}
    save_json(proof_path, proof)
    summary = ["Pass 3 regression wrapper proof", f"Baseline: {BASELINE}",
               f"Current: {proof['current_revision'] or 'pending source freeze'}",
               f"All proven: {proof['all_proven']}",
               "ID     baseline exit selected/executed   current exit selected/executed   paired"]
    for row in records:
        before = row.get("baseline", {})
        after = row.get("current", {})
        summary.append(f"{row['recommendation_id']:<6} {str(before.get('exit_code', '-')):>3} "
                       f"{before.get('selected_count', '-')}/{before.get('executed_count', '-'):<8} "
                       f"{str(after.get('exit_code', '-')):>18} "
                       f"{after.get('selected_count', '-')}/{after.get('executed_count', '-'):<8} "
                       f"{row['proven']}")
    summary.extend(["", "R013 overlaps R014-R022; this is wrapper coverage, not unique causal attribution.",
                    "R018 baseline stops after its failing process suite; current must execute both selectors.",
                    "R023 counts traced real-runner shell cases, including human output and cancellation.",
                    "Timeouts, incomplete selections, empty selections, and skipped current tests are rejected."])
    (out / "summary.txt").write_text("\n".join(summary) + "\n")
    stage_valid = all(row[stage]["proven"] for row in records for stage in stages)
    raise SystemExit(0 if stage_valid else 1)


if __name__ == "__main__":
    main()
