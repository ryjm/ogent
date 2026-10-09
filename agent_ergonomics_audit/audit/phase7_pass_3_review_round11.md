# Phase 7, pass 3, independent review round 11

**Verdict: NOT_CLEAN — one P2 substantive finding, zero trivial findings, zero source edits.**

Target: `/workspace/ogent`; sibling: `/workspace/ogent/agent_ergonomics_audit`; branch: `master`. Baseline: `b3caf9300c7336ef812ed061158f851c5a47ccf7`. Start and end frozen candidate: `021cca4d28e7b20fba3617c57522cc5014f640f9`.

This reviewer wrote only this report and `audit/evidence/pass_3/review_round11/`. Production source, repository tests, documentation, staging, and commits were read-only. The assignment's sole-repair coordination overrides the installed skill's reviewer-edit and commit steps. Root confirmed the documented raw-filename policy applies and owns the repair. The source end guard was captured before notifying root that repair could begin.

## Calibrated prompts applied verbatim

1. "Carefully read over all of the new code you just wrote and other existing code you just modified with 'fresh eyes' looking super carefully for any obvious bugs, errors, problems, issues, confusion, etc. Carefully fix anything you uncover."
2. "Sort of randomly explore the code files in this project, choosing code files to deeply investigate and trace their functionality and execution flows through the related code files which they import or which they are imported by. Once you understand the purpose of the code in the larger context of the workflows, do a super careful, methodical, and critical check with 'fresh eyes' to find any obvious bugs, problems, errors, silly mistakes. Comply with ALL rules in AGENTS.md and ensure that any code you write or revise conforms to the best practice guides referenced in AGENTS.md."
3. "Turn your attention to reviewing the code written by your fellow agents and checking for any issues, bugs, errors, problems, inefficiencies, security problems, reliability issues. Diagnose underlying root causes using first-principle analysis. Don't restrict yourself to the latest commits — cast a wider net and go super deep."

Instructions read: `AGENTS.md`; architecture, feature playbooks, style guide, and gptel integration specs; the relevant installed skill `SKILL.md` sections, `references/methodology/PHASES.md` Phase 7, and `subagents/fresh-eyes.md`. Read `applied_changes_pass_3.jsonl`, rounds 9 and 10 and their summaries, and the preserved scoped lint-hygiene probe/logs. The review used the complete baseline-to-freeze integration scope, with the prior clean evidence informing areas unchanged since `a2fa8ce`.

## Finding: P2 — structured glob silently drops selected raw-byte filenames

**Observed on Emacs 30.2 and 29.1, in both interpreted and compiled execution.** Create a real regular file whose basename is byte `FF` followed by `.txt`. An explicit structured `read` call returns the documented `unsupported_output` error. A structured `files` call for either `*.txt` or `**/*.txt` instead returns `status="ok"`, `files=[]`, and `total_files=0`.

The actual filesystem round trip explains the failure. Emacs directory enumeration decodes byte `FF` into its raw-byte character U+3FFFFF. In standalone `emacs -Q --batch`, outside the test helper, `file-exists-p` returns `t` for both the original unibyte path and that decoded path. However, `file-regular-p` returns `t` for the original unibyte path and `nil` for the decoded path. This distinction persists with the default, UTF-8, raw-text, and no-conversion filename coders in both runtimes. The file exists; an earlier provisional message describing the decoded path as nonexistent was corrected after the expanded diagnostics.

`ogent-tools--glob-files` applies `file-regular-p` to enumerated candidates at `lisp/ogent-tools.el:386`, dropping the raw-byte entry. `ogent-tool-results-glob` only calls `ogent-tool-results--unicode` on the remaining files at `lisp/ogent-tool-results.el:103`, so its intended unsupported-output guard never sees that entry. For recursive globs, `directory-files-recursively` can also discard that decoded entry before the later filter. This is a pre-validation enumeration/filtering issue, not a failure of the changed Unicode validator.

The output conflicts with `docs/agent-ergonomics.org:30–31`: "Structured file paths must be Unicode; unsupported raw filename bytes return unsupported_output". It also presents an incomplete matching-file set as a successful empty set. The regular-file predicate is inherited from the baseline legacy implementation; the new structured glob surface exposes this behavior under its typed-output contract. This finding is within the complete baseline-to-freeze review scope and was not introduced by the final lint commit.

**Repair direction sent to root:** validate selected filenames in the structured glob enumeration path before regular-file filtering or recursive enumeration can discard unsupported paths. Preserve legacy callers' behavior. Pin physical byte-FF filenames for flat and recursive structured globs, with a typed `unsupported_output` result rather than successful omission. The reviewer made no source repair.

Evidence:

- `compiled-unicode-probe.el`, test `ogent-round11-compiled-raw-path-sdk-boundaries`, fails on each runtime at the glob status assertion after explicit read has returned its typed error. Its later callback/batch assertions are not reached in these failing executions.
- `ogent-fixes-compiled-unicode.*` and `ogent-fixes-29-compiled-unicode.*` preserve both failures, exact argv, exits, timing, counts, stdout, and stderr.
- `raw-path-diagnostic.el` and both `*-raw-path-diagnostic-expanded.stdout` files show wildcard enumeration, the dropped candidate, both successful-empty glob results, and the explicit read error from source-loaded execution.
- `fixture-encoding-diagnostic.el` and both `*-fixture-encoding-expanded.stdout` files establish existence and regular-file predicate behavior without loading ogent or the test helper. Initial diagnostic transcripts remain alongside expanded ones.

## Review of the lint delta and wider integration

`021cca4` is the only commit after the previously reviewed `a2fa8ce`: it changes the `ogent-agent-batch` docstring and replaces `(progn (json-serialize text) text)` with `(when (json-serialize text) text)`. Successful `json-serialize` returns a non-nil string even for empty input, so the changed expression returns the same input string object. Serializer errors still become `ogent-tool-results-output-error`. Strict compilation and the independent compiled valid/invalid Unicode checks confirm the serializer remains executed in bytecode. The revised batch docstring describes the unchanged 20-call bound, required keys, full preflight, declared read-effects restriction, and fail-fast behavior accurately. No defect was found in those two edits themselves.

Traced named execution, native/JSON output, read/glob continuation positions and snapshots, alias/policy resolution, batch preflight and copied canonical calls, schema/object snapshots, post-approval registry validation, gptel wrapper/cache regeneration, synchronous and asynchronous terminal delivery, process startup/timeout/cancel/drain cleanup, and the captured-ledger destination/error retention paths. Reviewed the relevant changes in `ogent-agent.el`, `ogent-tool-results.el`, `ogent-tools.el`, `ogent-tool-execution.el`, `ogent-tool-process.el`, `ogent-tool-contract.el`, `ogent-tool-approval.el`, `ogent-models.el`, `ogent-debug.el`, and `ui/ogent-ui-toolcalls.el`; expanded into ledger append IO and the explicit-source test bootstrap. Reviewed Make/CI integration and build-report command/task exits, stdout/stderr routing, and diagnostic normalization. No second reproducible source defect was identified.

The latest commit leaves the product tests and the rest of that integration byte-identical to the previously clean candidate. Prior rounds 9/10 and root's preserved native/scoped lint evidence remain historical evidence; this reviewer does not relabel those checks as runs on the new candidate.

## Actual bounded verification

Both containers used `-Q --batch`, `/work` as the working directory, the four requested load paths, explicit `/work/test/ogent-test-helper.el`, and `OGENT_PROCESS_TEST_RG=/tmp/ogent-test-rg`. Actual versions were Emacs 30.2 and 29.1; ripgrep was 15.2.0. The helper excludes stale `.elc` dependencies. Both changed source files were explicitly loaded. The SDK run loaded only the actual `/work/test/ogent-agent-execution-tests.el` suite and selected its namespace.

The compiled probe warning-strictly compiled both changed files into a retained private test store, explicitly loaded the new `ogent-tool-results.elc`, and asserted its Unicode validator is bytecode. It tested supported-string object identity and JSON round trips, three mixed raw-byte inputs, Unicode characters reconstructed through multiple SDK JSON continuation pages, and the physical raw-filename SDK boundary. Compilation of both files succeeded without warnings on both versions. Existing root scoped checkdoc/indentation evidence was inspected; it was not rerun by this reviewer.

| Run | Selected | Expected | Unexpected | Skipped | Exit |
| --- | ---: | ---: | ---: | ---: | ---: |
| SDK suite, Emacs 30.2 | 53 | 53 | 0 | 0 | 0 |
| SDK suite, Emacs 29.1 | 53 | 53 | 0 | 0 | 0 |
| Independent compiled probe, Emacs 30.2 | 4 | 3 | 1 | 0 | 1 |
| Independent compiled probe, Emacs 29.1 | 4 | 3 | 1 | 0 | 1 |

**Exact execution totals: 114 ERT executions of 57 distinct tests, 112 expected results, two unexpected results reproducing the same P2, zero skips.** There was no test/probe rerun that replaced or hid those failures. Diagnostic invocations are separate non-ERT evidence. All runs and counts are recorded in `bounded_runs.json` and `summary.json`; versions have their own metadata files.

No full native/make matrix, broad build-report runtime battery, provider login, or inference was run by this reviewer. Root owns repair and subsequent full gates. This report does not declare Phase 7 complete.

## Source guards and round status

`source_guard_start.json` and `source_guard_end.json` both identify `021cca4d28e7b20fba3617c57522cc5014f640f9` on `master`. Staged and unstaged diffs are empty for `lisp`, `test`, `docs`, `specs`, `Makefile`, `makem.sh`, `README.md`, `README.org`, `.github`, and `AGENTS.md`. All **226 tracked file SHA-256 hashes** in those paths match start/end. `source_guard_comparison.json` records these checks. `baseline_diff_check.json` records exit 0 with empty stdout/stderr for the complete baseline-to-freeze whitespace check. `lint_commit.diff` preserves the exact last-commit delta; `changed_files.txt` preserves the complete changed-file range.

**Round 11 NOT_CLEAN. One P2 was routed to root. After the repair, two new consecutive independent clean rounds are required before the final full native gate.**
