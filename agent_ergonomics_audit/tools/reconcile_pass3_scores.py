"""Preserve paired raw judgments and invoke the installed rubric aggregator."""
import argparse
import datetime
import hashlib
import json
import statistics
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
WORK = REPO / "agent_ergonomics_audit"
AUDIT = WORK / "audit"
SKILL = Path("/home/agent/.claude/skills/agent-ergonomics-and-intuitiveness-maximization-for-cli-tools")
BASELINE = "b3caf9300c7336ef812ed061158f851c5a47ccf7"


def read_rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def write_rows(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--current-sha", required=True)
    current = parser.parse_args().current_sha
    assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip() == current
    historical = [row for row in read_rows(AUDIT / "agent_surfaces.jsonl") if row["pass"] <= 2]
    assert len(historical) == 38
    inputs = []
    partial = AUDIT / "partial"
    archive = AUDIT / "evidence/pass_3/triangulation"
    for label, dirname in (("A", "scorerA"), ("B", "scorerB"), ("T", "tiebreaker")):
        for pass_num, state, target in ((3, "baseline", BASELINE), (4, "current", current)):
            if state == "baseline":
                source = AUDIT / f"evidence/pass_3/{dirname}/baseline_paired_scores.jsonl"
            elif label == "T":
                source = AUDIT / "evidence/pass_3/tiebreaker/current_scores.jsonl"
            else:
                source = partial / f"scores_pass4_current_scorer{label}.jsonl"
                if not source.exists():
                    source = archive / f"current/scorer{label}.jsonl"
            rows = read_rows(source)
            assert len(rows) == (9 if label == "T" else 19)
            assert len({r["surface_id"] for r in rows}) == len(rows)
            assert all(r["target_sha"] == target for r in rows)
            destination = archive / f"{state}/scorer{label}.jsonl"
            destination.parent.mkdir(parents=True, exist_ok=True)
            if source.parent == partial:
                source.rename(destination)
            else:
                destination.write_bytes(source.read_bytes())
            inputs.append({"pass": pass_num, "scorer": label, "source": str(source.relative_to(WORK)),
                           "archive": str(destination.relative_to(WORK)), "rows": len(rows),
                           "sha256": hashlib.sha256(destination.read_bytes()).hexdigest()})
            for row in rows:
                write_rows(partial / f"scores_pass{pass_num}_{row['surface_id']}_scorer{label}.jsonl", [row])
    manifest_path = AUDIT / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    for pass_num in (3, 4):
        manifest["current_pass"] = pass_num
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        subprocess.run(["bash", str(SKILL / "scripts/aggregate_scores.sh"), str(WORK)], check=True)
    rows = read_rows(AUDIT / "agent_surfaces.jsonl")
    assert [r for r in rows if r["pass"] <= 2] == historical
    assert len(rows) == 76
    assert len({(r["pass"], r["surface_id"]) for r in rows}) == 76
    paired = {p: {r["surface_id"]: r for r in rows if r["pass"] == p} for p in (3, 4)}
    assert paired[3].keys() == paired[4].keys()
    deltas = {sid: paired[4][sid]["weighted_score"] - paired[3][sid]["weighted_score"] for sid in paired[3]}
    new_rows = {s: read_rows(AUDIT / f"evidence/pass_3/scorer{s}/new_api_scores.jsonl") for s in ("A", "B")}
    new_apis = []
    for first in new_rows["A"]:
        second, = [r for r in new_rows["B"] if r["surface_id"] == first["surface_id"]]
        assert first["target_sha"] == second["target_sha"] == current
        scores = {dim: int(statistics.median([value, second["scores"][dim]])) for dim, value in first["scores"].items()}
        spread = max(abs(first["scores"][dim] - second["scores"][dim]) for dim in scores)
        assert spread <= 300
        new_apis.append({"surface_id": first["surface_id"], "pass": 4, "rubric_version": first["rubric_version"],
                         "target_sha": current, "scores": scores, "weighted_score": sum(scores.values()) // len(scores),
                         "score_confidence": {"spread_max": spread, "tiebroken": False},
                         "evidence": {**second["evidence"], **first["evidence"]}, "notes": first.get("notes", ""),
                         "scored_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                         "comparison": "unpaired new API; excluded from historical paired mean"})
    assert len(new_apis) == 6
    write_rows(AUDIT / "new_api_surfaces_pass_4.jsonl", new_apis)
    gains = {dim: statistics.mean(paired[4][sid]["scores"][dim] - paired[3][sid]["scores"][dim] for sid in paired[3])
             for dim in next(iter(paired[3].values()))["scores"]}
    summary = {"baseline_sha": BASELINE, "current_sha": current, "paired_surfaces": 19, "unpaired_new_apis": 6,
               "baseline_mean": statistics.mean(r["weighted_score"] for r in paired[3].values()),
               "post_mean": statistics.mean(r["weighted_score"] for r in paired[4].values()),
               "median_uplift_all_19": statistics.median(deltas.values()),
               "median_uplift_10_changed_originals": statistics.median(d for d in deltas.values() if d),
               "changed_originals": sum(d != 0 for d in deltas.values()),
               "surfaces_with_dimension_uplift_ge_100": sum(any(paired[4][sid]["scores"][dim] - value >= 100
                   for dim, value in paired[3][sid]["scores"].items()) for sid in paired[3]),
               "regressions_over_50": [sid for sid, delta in deltas.items() if delta < -50],
               "deltas": deltas, "dimension_mean_gains": gains,
               "method": "floored per-dimension median, floored equal-weight mean; same-model qualitative judgments",
               "inputs": inputs}
    (archive / "aggregation.json").write_text(json.dumps(summary, indent=2) + "\n")
    for pass_num in (3, 4):
        with (AUDIT / f"scorecard_pass_{pass_num}.md").open("w") as out:
            subprocess.run(["bash", str(SKILL / "scripts/render_scorecard.sh"), str(AUDIT / "agent_surfaces.jsonl"),
                            "--pass", str(pass_num)], check=True, stdout=out)
    with (AUDIT / "heatmap_pass_4.svg").open("w") as out:
        subprocess.run(["bash", str(SKILL / "scripts/render_heatmap.sh"), str(AUDIT / "agent_surfaces.jsonl"),
                        "--pass", "4"], check=True, stdout=out)
    with (AUDIT / "uplift_diff_pass_3.md").open("w") as out:
        subprocess.run(["bash", str(SKILL / "scripts/diff_scorecards.sh"), str(AUDIT / "agent_surfaces.jsonl"),
                        "3", "4"], check=True, stdout=out)
    (AUDIT / "scorecard.md").write_bytes((AUDIT / "scorecard_pass_4.md").read_bytes())
    with (AUDIT / "new_api_scorecard_pass_4.md").open("w") as out:
        subprocess.run(["bash", str(SKILL / "scripts/render_scorecard.sh"), str(AUDIT / "new_api_surfaces_pass_4.jsonl"),
                        "--pass", "4"], check=True, stdout=out)
    print(json.dumps({key: value for key, value in summary.items() if key not in ("inputs", "deltas", "dimension_mean_gains")}, indent=2))


if __name__ == "__main__":
    main()
