"""Build durable evidence and metrics from this simulation's own transcript only."""
import collections
import json
import pathlib
import shlex

root = pathlib.Path(__file__).resolve().parent
records = [json.loads(line) for line in (root / "transcript.jsonl").read_text().splitlines()]
for number, record in enumerate(records, 1):
    record["transcript_record"] = number

definitions = {
    "attempts": "Problem-solving strategy attempts; planned paging and safety phases remain one strategy.",
    "round_trips": "Product query/execute subprocess calls, excluding fixture setup, fixture workaround writes, and transcript verification. Task 7 includes Makefile help.",
    "first_try": "The first problem-solving strategy fulfilled the whole goal; intentional invalid-regex and ambiguous-edit probes are expected checks, not failed strategies.",
    "stuck_tokens": "Literal API, command, or syntax tokens associated with an observed discovery/blocking point; this is not sampled model token usage.",
    "stuck_inference_token_count": "Unavailable: the execution tool does not report per-task sampled inference token usage; no count was fabricated.",
}
tasks = [
    {
        "task": 1, "goal": "Discover tool names, argument types, approval expectations, and unknown-tool correction.",
        "attempts": 2, "round_trips": 2, "first_try": False,
        "stuck_tokens": ["^ogent-.*tool", "ogent-agent-capabilities"],
        "outcome": "success", "workaround_used": False,
        "evidence": "Initial tool-only apropos documentation did not give registered names/types. Second query printed six live registry contracts, confirmation metadata, and a corrective unknown-tool error. Runtime capabilities/guide were subsequently verified in one separate documentation query.",
    },
    {
        "task": 2, "goal": "Find .el files recursively at root and two nested depths.",
        "attempts": 1, "round_trips": 1, "first_try": True, "stuck_tokens": [],
        "outcome": "success", "workaround_used": False,
        "evidence": "**/*.el returned root.el, nested/one.el, and nested/deep/two.el; ignored the .txt fixture.",
    },
    {
        "task": 3, "goal": "Read a fixture in two-line pages and derive exact next-page arguments from output.",
        "attempts": 1, "round_trips": 3, "first_try": True, "stuck_tokens": [],
        "outcome": "success", "workaround_used": False,
        "evidence": "First footer specified identical file_path, offset=3, limit=2; second specified offset=5, limit=2. Those arguments were followed sequentially. Final page returned line 5 with no more-lines footer.",
    },
    {
        "task": 4, "goal": "Search a leading-dash pattern and distinguish no matches from invalid regex.",
        "attempts": 1, "round_trips": 1, "first_try": True, "stuck_tokens": [],
        "outcome": "success", "workaround_used": False, "tool_calls": 3,
        "evidence": "-needle matched. Valid absent pattern returned No matches found. Invalid [ signaled user-error with grep exit 2 and corrective guidance. That signal was intentionally caught to capture all three classifications in one query.",
    },
    {
        "task": 5, "goal": "Safely handle two occurrences of same, then explicitly replace all.",
        "attempts": 1, "round_trips": 2, "first_try": True, "stuck_tokens": [],
        "outcome": "success", "workaround_used": False, "tool_calls": 4,
        "evidence": "Default edit signaled Ambiguous edit_file ... matches 2 occurrences and suggested unique context or replace_all. Read-back showed both same lines intact. Explicit replace_all=t reported two replacements; read-back showed both updated lines.",
        "limitation": "Documented low-level direct SDK functions were used on authorized temporary fixtures; approval enforcement was discovered through metadata but not exercised.",
    },
    {
        "task": 6, "goal": "Obtain parseable JSON local health without provider requests.",
        "attempts": 1, "round_trips": 1, "first_try": True, "stuck_tokens": [],
        "outcome": "success", "workaround_used": False,
        "evidence": "ogent-agent-triage json returned a clean document, strictly parsed by Python. contract_version=1; 19 checks; project_health.status=error and exit_code=2; process status=0 because triage returns data. Test doubles/base package versions account for local health deficiencies; provider inference/login/network checks were not invoked.",
    },
    {
        "task": 7, "goal": "Compile with deliberately failing selected Emacs in an isolated Makefile fixture and detect failure from status.",
        "attempts": 2, "round_trips": 3, "first_try": False, "stuck_tokens": ["./makem.sh"],
        "outcome": "success_with_fixture_workaround", "workaround_used": True,
        "evidence": "make help documented compile and EMACS=PATH. Initial Makefile-only fixture returned status 2 because makem.sh was absent; this did not prove selected-Emacs failure. Added a fixture-only helper that requires the selected path in argv and propagates its status. Retry reached selected Emacs, which exited 47; make reported Error 47 and returned status 2. Full helper/selected argv were captured.",
        "limitation": "Tests copied Makefile failure propagation and selected executable forwarding with a temporary passthrough; actual makem.sh implementation was neither read nor copied, so real compiler/makem integration is not covered.",
    },
]
for task in tasks:
    matching = [r for r in records if r["task"] == str(task["task"])]
    task["transcript_records"] = [r["transcript_record"] for r in matching]
    task["all_recorded_commands"] = len(matching)
    task["stuck_inference_token_count"] = None

optional = {
    "probe": "recompile with failing selected Emacs", "included_in_paired_metrics": False,
    "attempts": 1, "round_trips": 1, "first_try": True, "stuck_tokens": [],
    "outcome": "success_with_same_fixture_limitation", "make_status": 2,
    "evidence": "Recompile removed both temporary .elc sentinels, forwarded the selected Emacs path, and reported child Error 47 then parent Error 2. No shared bytecode was cleaned or compiled.",
    "transcript_records": [r["transcript_record"] for r in records if r["task"] == "optional-recompile"],
}
metrics = {
    "simulation": "post_pass_1/canonical", "candidate_supplied_by_parent": "303fa14",
    "fresh_context": True, "runtime": "Docker ogent-fixes, Emacs 30.2, permitted bootstrap/test doubles",
    "metric_definitions": definitions, "tasks": tasks, "optional_probe": optional,
    "aggregate": {
        "goals_completed": 7, "paired_goals": 7,
        "first_try_count": sum(t["first_try"] for t in tasks),
        "first_try_rate": sum(t["first_try"] for t in tasks) / len(tasks),
        "strategy_attempts": sum(t["attempts"] for t in tasks),
        "product_round_trips": sum(t["round_trips"] for t in tasks),
        "additional_shared_discovery_round_trips": 1,
        "round_trips_including_shared_discovery": sum(t["round_trips"] for t in tasks) + 1,
        "fixture_workaround_tasks": [7],
    },
    "constraints": {
        "product_information_used": ["Runtime Emacs documentation/apropos", "Live registry/capabilities metadata", "Runtime agent guide", "Makefile help"],
        "source_exception": "Copied Makefile only to temporary fixture; no implementation source, README, AGENTS, prior audit artifacts, baseline outcomes, scorer reports, or other agents were read.",
        "provider_requests_or_logins": False, "credentials_read": False,
        "production_source_store_cache_or_shared_bytecode_mutations": False,
        "repo_write_scope": str(root), "git_commits": False,
    },
    "limitations": [
        "Candidate hash supplied by task, not independently inspected through git.",
        "Bootstrap emitted an OAuth-support-enabled message; no OAuth/login function or provider request was called. Health reports inspected only absent auth paths in isolated test stores.",
        "Direct low-level SDK calls do not exercise registered approval enforcement.",
        "Capabilities reported async=false for all tools while raw grep/bash specs named async functions; observation retained without assigning a cause under source-blind constraints.",
        "Per-task sampled inference token counts are unavailable; stuck_tokens lists literal blocked/discovery tokens transparently.",
        "Two preliminary tool-channel environment checks (pwd and docker ps) preceded exact stream capture. Their visible combined results were /workspace/ogent and the two running ogent-fixes containers, both exit 0. docker ps was repeated under full capture; no product action preceded recording.",
    ],
}
(root / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")

parts = ["Fresh-context usability simulation: post_pass_1/canonical\n", "Candidate supplied: 303fa14; Docker ogent-fixes / Emacs 30.2.\n", "Completed 7/7 paired goals; first strategy succeeded in 5/7. Task 7 required a recorded temporary-helper workaround.\n", "Counts: 9 strategy attempts, 13 product round trips, plus 1 shared runtime-guide/capabilities query. Fixture setup and verification commands are separately retained.\n"]
for task in tasks:
    parts.append(f"\nTask {task['task']}: {task['goal']}\n")
    parts.append(f"Outcome: {task['outcome']}; attempts={task['attempts']}; round_trips={task['round_trips']}; first_try={task['first_try']}; stuck_tokens={task['stuck_tokens']}\n")
    parts.append(task["evidence"] + "\n")
    if "limitation" in task:
        parts.append("Limit: " + task["limitation"] + "\n")
parts.append("\nOptional recompile probe (excluded from paired metrics):\n" + optional["evidence"] + "\n")
parts.append("\nLimits and recording notes:\n" + "\n".join("- " + x for x in metrics["limitations"]) + "\n")
parts.append("\nArtifacts: transcript.jsonl (full argv/stdout/stderr/status), transcript.txt (readable rendering), metrics.json, health.json, run_probe.py, write_summary.py.\n")
(root / "summary.txt").write_text("".join(parts))

with (root / "transcript.txt").open("w") as stream:
    for record in records:
        stream.write(f"Record {record['transcript_record']} | task={record['task']} | kind={record['kind']}\n")
        stream.write("Note: " + record["note"] + "\n")
        stream.write("ARGV JSON: " + json.dumps(record["argv"]) + "\n")
        stream.write("Command: " + shlex.join(record["argv"]) + "\n")
        stream.write(f"CWD: {record['cwd']}\nStatus: {record['status']}\n")
        stream.write("STDOUT:\n" + record["stdout"] + "\nSTDERR:\n" + record["stderr"] + "\n\n")
print(json.dumps({"aggregate": metrics["aggregate"], "records_rendered": len(records), "artifact_directory": str(root)}))
