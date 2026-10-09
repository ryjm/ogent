"""Validate the completed local handoff without repeating runtime tests."""
import gzip
import hashlib
import json
import subprocess
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
WORKSPACE = REPO / "agent_ergonomics_audit"
AUDIT = WORKSPACE / "audit"
FREEZE = "5d07d807bc85a093725db24e33996b4af690ec0f"
BASELINE = "b3caf9300c7336ef812ed061158f851c5a47ccf7"


def read(name):
    return json.loads((AUDIT / name).read_text())


def rows(name):
    return [json.loads(line) for line in (AUDIT / name).read_text().splitlines() if line]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    proof = read("verification/pass_3/regression_proof.json")
    ids = {f"R{number:03}" for number in range(13, 24)}
    assert proof["all_proven"] and proof["current_revision"] == FREEZE
    assert {row["recommendation_id"] for row in proof["records"]} == ids
    for name in ("recommendations_pass_3.jsonl", "applied_changes_pass_3.jsonl"):
        data = rows(name)
        assert len(data) == 11 and {row["recommendation_id"] for row in data} == ids
        assert all(row["final_source_revision"] == FREEZE for row in data)
        assert all(row["consecutive_clean_review_count"] == 2 for row in data)
    integrity = read("verification/pass_3/regressions/integrity_check.json")
    assert integrity["all_checks_passed"] and integrity["current_revision"] == FREEZE
    assert (integrity["checked_transcripts"], integrity["checked_input_hashes"]) == (22, 47)
    controls = read("verification/pass_3/regressions/recorder_validation.json")
    assert controls["all_passed"] and len(controls["negative_controls"]) == 6
    for number in (14, 15):
        folder = f"evidence/pass_3/review_round{number}"
        start, end = read(f"{folder}/guard-start.json"), read(f"{folder}/guard-end.json")
        assert start["head"] == end["head"] == FREEZE
        assert start["hashes"] == end["hashes"] and len(end["hashes"]) == 241
        assert "**Verdict: CLEAN.**" in (AUDIT / f"phase7_pass_3_review_round{number}.md").read_text()
    native = read("verification/pass_3/native_checks.json")
    assert native["all_passed"] and len(native["checks"]) == 8
    assert native["source_sha"] == native["completed_sha"] == FREEZE
    assert native["source_fingerprint"] == native["completed_fingerprint"]
    for check in native["checks"]:
        assert check["exit_code"] == 0 and check["source_sha"] == FREEZE
        for stream in ("stdout", "stderr"):
            packed = (WORKSPACE / check[stream]).read_bytes()
            hashes = check["transcript_hashes"][stream]
            assert digest(packed) == hashes["gzip_sha256"]
            assert digest(gzip.decompress(packed)) == hashes["raw_sha256"]
    replay = read("agent_simulations/post_pass_3/final_freeze/summary.json")
    assert replay["source_sha_start"] == replay["source_sha_end"] == FREEZE
    assert replay["final_state"] == "complete" and not replay["fresh_discovery_or_efficiency_claim"]
    scores = rows("agent_surfaces.jsonl")
    assert len(scores) == 76 and len(rows("new_api_surfaces_pass_4.jsonl")) == 6
    old = subprocess.check_output(["git", "show", f"{BASELINE}:agent_ergonomics_audit/audit/agent_surfaces.jsonl"], cwd=REPO, text=True)
    assert [row for row in scores if row["pass"] <= 2] == [json.loads(line) for line in old.splitlines() if line]
    manifest = read("manifest.json")
    assert manifest["passes"][2]["summary"]["consecutive_final_clean_rounds"] == [14, 15]
    assert manifest["passes"][3]["scored_source_freeze"] == FREEZE
    for label in ("validate-pass", "validate-scorecard", "validate-new-api-scorecard"):
        assert read(f"verification/pass_3/artifact_validation/{label}.json")["exit_code"] == 0
    safety = read("verification/pass_3/discovery_safety.json")
    assert not safety["audit_features_or_tests"] and not safety["tracked_audit_source_snapshots"]
    subprocess.run(["git", "diff", "--quiet", FREEZE, "--", "lisp", "test", "docs", "README.org", "makem.sh", "Makefile", ".github"], cwd=REPO, check=True)
    result = {"source_revision": FREEZE, "recommendations": 11, "proof_pairs": 11,
              "consecutive_clean_reviews": [14, 15], "native_checks": 8,
              "paired_score_rows": 76, "new_api_rows": 6, "all_checks_passed": True,
              "scope": "Local artifact consistency; exact pushed-SHA CI is verified separately."}
    (AUDIT / "verification/pass_3/handoff_integrity.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
