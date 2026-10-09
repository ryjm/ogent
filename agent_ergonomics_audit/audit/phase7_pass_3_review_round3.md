# Phase 7, pass 3: independent fresh-eyes round 3

**Result: not clean.** Two reproducible behavior defects remain at frozen source
`3cb0cd721c58c34550c6e01a04bb13f62241ad83`. Both were sent to the integration
owner, who owns production corrections. This reviewer changed only this report
and its dedicated evidence directory.

## Scope and method

Read `AGENTS.md`, the skill `SKILL.md` and `references/methodology/PHASES.md`,
and the repository architecture, style, gptel integration, and feature
playbooks. Reviewed the applied range
`b3caf9300c7336ef812ed061158f851c5a47ccf7..3cb0cd721c58c34550c6e01a04bb13f62241ad83`,
including the SDK, execution and argument contracts, structured file/process
results, policy and registry integration, debug history/replay, Makefile,
`makem.sh`, documentation and relevant test coverage. Traced named calls through
validation, approval, registry checks, execution, ledger/history and result
serialization; traced search through both real subprocess engines and build
reports through actual compiler/ERT output.

The three calibrated review prompts were applied verbatim, with corrections
delegated to the integration owner under the explicit review-only assignment:

1. “Carefully read over all of the new code you just wrote and other existing code you just modified with ‘fresh eyes’ looking super carefully for any obvious bugs, errors, problems, issues, confusion, etc. Carefully fix anything you uncover.”
2. “Sort of randomly explore the code files in this project, choosing code files to deeply investigate and trace their functionality and execution flows through the related code files which they import or which they are imported by. Once you understand the purpose of the code in the larger context of the workflows, do a super careful, methodical, and critical check with ‘fresh eyes’ to find any obvious bugs, problems, errors, silly mistakes. Comply with ALL rules in AGENTS.md and ensure that any code you write or revise conforms to the best practice guides referenced in AGENTS.md.”
3. “Turn your attention to reviewing the code written by your fellow agents and checking for any issues, bugs, errors, problems, inefficiencies, security problems, reliability issues. Diagnose underlying root causes using first-principle analysis. Don’t restrict yourself to the latest commits — cast a wider net and go super deep.”

Every runtime invocation explicitly loaded `test/ogent-test-helper.el` before
project source. Emacs 30.2 and Emacs 29.1 ran in the existing `ogent-fixes` and
`ogent-fixes-29` containers. Probes used real GNU grep/xargs and actual ripgrep
at `/tmp/ogent-test-rg`; the lookup override selects the engine only. No
provider requests or authentication were used. No source, tests, or product
documentation was edited, and no changes were staged or committed. Source
matched the freeze at the beginning and end; both recorded production diffs
are empty.

## Findings

1. **P1: a mutable batch call record bypasses the read-only preflight.**

   `lisp/ogent-agent.el:108` copies each registry spec but retains the caller's
   original call plist. At line 112 the comparison checks the copied original
   spec, while line 113 executes the current `:tool` and `:args` from the live
   call record. The executed name therefore need not be the preflighted name.

   The independent fixture prepares two declared read calls. The first read
   changes the second call's `:tool` to a separate declared write fixture;
   registry entries remain unchanged. With an existing permissive approval
   policy, `ogent-agent-batch` executes the write fixture, returns overall
   `status="ok"`, and includes a successful `write-fixture` result. The recorded
   write-run count is **1**. This is a batch safety-contract failure independent
   of ordinary per-call approval: the batch contract promises to reject writes
   even when those writes are separately authorized.

   Freeze the validated execution plan, including the canonical tool name and
   its argument values, instead of consulting caller-owned records after
   preflight. Retain the existing registry snapshot check. Evidence:
   `evidence/pass_3/review_round3/flow-probe.el`, terminal records
   `BATCH CALL MUTATION` and `BATCH WRITE RUNS` in `flow-probe-30.stdout`.

2. **P2: directory search path-glob semantics change when ripgrep is installed.**

   `lisp/ogent-tool-process.el:265` builds the GNU candidate filter with
   `wildcard-to-regexp`; lines 272–273 apply it to the basename or relative path.
   That matcher allows `*` to span directory components and does not give `**/`
   its zero-directory meaning. The ripgrep path sends the same public
   `glob_filter` directly to ripgrep, which uses component-aware glob rules.

   Create `src/direct.txt` and `src/deep/nested.txt`, both containing `needle`.
   The same named search with `glob_filter="src/*.txt"` returns **2** matches
   through GNU grep and **1** through ripgrep. With
   `glob_filter="src/**/*.txt"`, GNU returns **1** and ripgrep returns **2**.
   The first difference searches outside the requested component; the second
   silently loses a matching file. This uses ordinary path globs and is
   unrelated to the documented regular-expression dialect difference.

   Give both engines a deliberate common path-glob rule, including single-star
   component boundaries and zero-depth `**/`, or reject an unsupported filter
   explicitly. The newly added component-aware file-glob matcher already
   addresses these two semantics elsewhere in the package. Evidence:
   `flow-probe.el`, the `FILTER "src/*.txt"` and `FILTER "src/**/*.txt"`
   GNU/ripgrep records in `flow-probe-30.stdout`.

## Verification and non-findings

- Emacs 30 focused SDK/process/debug suites: **174 tests, 174 expected, zero
  unexpected**, with actual ripgrep enabled. Full transcript:
  `focused-ert-30.out`.
- Emacs 29 focused SDK/process/debug suites: **174 tests, 174 expected, zero
  unexpected**, with actual ripgrep enabled. Full transcript:
  `focused-ert-29.out`.
- Actual tracked build-report fixture: **all real-runner checks passed**.
  This includes successful compilation, real compiler warnings, compiler and
  load syntax-error positions, ambiguous nested-load ownership, ERT failures
  with source locations, Unicode output/arguments, Make integration, bootstrap
  errors and cancellation. Transcript: `makem-real-fixture-30.out`.
- Replayed the previous in-place registry mutation reproduction: text and JSON
  wrappers reject the changed spec and never run the replacement; the batch
  refuses the changed second spec. Transcript:
  `inplace-registry-fixed.stdout` and `.stderr`.
- Raw-byte filenames now produce a typed `unsupported_output` envelope in both
  synchronous and immediate asynchronous JSON calls; the async callback runs
  exactly **once**. The valid smaller read maximum defaults correctly.
- A structured read with `:column` successfully replays through real debug
  history. A structured shell `exit 7` records retained stdout and
  `:error "command_failed"` in history. These earlier findings remain fixed.
- Literal explicit filenames containing brackets, braces, exclamation marks
  and stars return the same exact match in both engines. Simple `*.txt`
  directory filtering also agrees in the independent fixture.

This round requires another review after correction of the two findings; it
does not count toward the required two consecutive clean rounds. Subsequent
production corrections are outside this frozen-source certification.
