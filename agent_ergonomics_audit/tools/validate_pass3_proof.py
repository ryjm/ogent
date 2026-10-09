"""Check recorded regression evidence without rerunning completed tests."""
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess


def main():
    repo = Path(__file__).resolve().parents[2]
    audit = repo / "agent_ergonomics_audit/audit"
    folder = audit / "verification/pass_3/regressions"
    proof = json.loads((folder.parent / "regression_proof.json").read_text())
    current = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    assert proof["current_revision"] == current
    assert proof["status"] == "complete" and proof["all_proven"]
    assert len(proof["records"]) == 11
    assert not subprocess.check_output(["git", "status", "--porcelain", "--", "lisp", "test", "makem.sh", "Makefile"], cwd=repo, text=True).strip()

    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    verifier = repo / proof["verifier"]["path"]
    assert digest(verifier) == proof["verifier"]["sha256"]
    spec = importlib.util.spec_from_file_location("ogent_proof_recorder", verifier)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    transcripts = inputs = 0
    for row in proof["records"]:
        assert row["proven"]
        for path, expected in row["test_inputs_sha256"].items():
            assert digest(repo / path) == expected, path
            if path.startswith(("test/", "lisp/")) or path == "Makefile":
                body = subprocess.check_output(["git", "show", f"{current}:{path}"], cwd=repo)
                assert hashlib.sha256(body).hexdigest() == expected, path
            inputs += 1
        for stage in ("baseline", "current"):
            record = row[stage]
            assert record["proven"] and not record["evidence_errors"]
            assert not record["timed_out"] and record.get("skipped_count", 0) == 0
            assert record["exit_code"] == (1 if stage == "baseline" else 0)
            assert record["selected_count"] == record["executed_count"] > 0
            large = stage == "baseline" and row["contract"]["expected_count"] > 40
            assert record["timeout_seconds"] == (150 if large else 90)
            path = repo / record["log"]
            assert digest(path) == record["log_sha256"]
            parser = module.parse_ert if row["contract"]["kind"] == "ert" else module.parse_shell
            parsed = parser(path.read_text(), row["contract"], stage)
            assert not parsed["evidence_errors"]
            assert parsed["selected_count"] == record["selected_count"]
            source = record["source"]
            manifest = repo / source["manifest"]
            assert digest(manifest) == source["manifest_sha256"]
            snapshot = json.loads(manifest.read_text())
            assert snapshot["revision"] == (proof["baseline_revision"] if stage == "baseline" else current)
            assert source["tracked_source_clean"]
            for name, expected in snapshot["files_sha256"].items():
                body = subprocess.check_output(["git", "show", f"{snapshot['revision']}:{name}"], cwd=repo)
                assert hashlib.sha256(body).hexdigest() == expected, name
                if stage == "current":
                    assert digest(repo / name) == expected, name
            transcripts += 1

    ert = proof["records"][0]
    good = (repo / ert["current"]["log"]).read_text()
    bad = (repo / ert["baseline"]["log"]).read_text()
    shell = proof["records"][-1]
    shell_good = (repo / shell["current"]["log"]).read_text()
    controls = {
        "empty_ert_selection_rejected": bool(module.parse_ert("Running 0 tests\nRan 0 tests, 0 results as expected, 0 unexpected\n", ert["contract"], "current")["evidence_errors"]),
        "truncated_ert_transcript_rejected": bool(module.parse_ert(module.ERT_END.sub("", good), ert["contract"], "current")["evidence_errors"]),
        "baseline_pass_rejected": bool(module.parse_ert(good, ert["contract"], "baseline")["evidence_errors"]),
        "current_failures_rejected": bool(module.parse_ert(bad, ert["contract"], "current")["evidence_errors"]),
        "baseline_shell_success_rejected": bool(module.parse_shell(shell_good, shell["contract"], "baseline")["evidence_errors"]),
        "incomplete_current_shell_fixture_rejected": bool(module.parse_shell(shell_good.replace("makem JSON contract: all real-runner checks passed\n", ""), shell["contract"], "current")["evidence_errors"]),
    }
    assert all(controls.values())
    historical = audit / "verification/regression_proof.json"
    assert historical.read_bytes() == subprocess.check_output(["git", "show", f"{proof['baseline_revision']}:agent_ergonomics_audit/audit/verification/regression_proof.json"], cwd=repo)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    integrity = {
        "recorded_at": now, "baseline_revision": proof["baseline_revision"], "current_revision": current,
        "source_status": "frozen_final_candidate", "checked_transcripts": transcripts,
        "checked_input_hashes": inputs, "current_source_matches_git_archive": True,
        "source_manifest_hashes_valid": True, "fixture_hashes_match_frozen_git_revision": True,
        "selected_counts_equal_executed_counts": True, "zero_skipped_tests": True,
        "zero_timeouts": True, "expanded_timeout_only_for_baseline_selectors_over_40_tests": True,
        "large_baseline_timeout_seconds": 150, "verifier_hash_valid": True,
        "historical_pass_1_proof_unchanged": True, "all_checks_passed": True,
    }
    (folder / "integrity_check.json").write_text(json.dumps(integrity, indent=2) + "\n")
    validation = {"recorded_at": now, "verifier_sha256": digest(verifier),
                  "transcript_fixture_revision": current, "negative_controls": controls, "all_passed": True}
    (folder / "recorder_validation.json").write_text(json.dumps(validation, indent=2) + "\n")
    print(json.dumps({"revision": current, "transcripts": transcripts, "input_hashes": inputs, "negative_controls": len(controls), "all_checks_passed": True}))


if __name__ == "__main__":
    main()
