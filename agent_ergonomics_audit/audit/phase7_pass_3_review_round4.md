# Phase 7, pass 3: independent fresh-eyes round 4

**Result: not clean.** Two reproducible P2 contract defects remain at frozen
source `90818f808bee4f9ff26f84c3f1235e24d469d927`. Both were sent to the integration
owner, who owns corrections. This reviewer changed only this report and its
dedicated evidence directory, and performed no staging or commits.

## Scope and method

Read `AGENTS.md`, the skill `SKILL.md` and `references/methodology/PHASES.md`,
and the repository architecture, style, gptel integration and feature
playbooks. Reviewed the applied range
`b3caf9300c7336ef812ed061158f851c5a47ccf7..90818f808bee4f9ff26f84c3f1235e24d469d927`,
including the SDK, argument validation and copying, batch preflight, registry
snapshots, approval, structured file/process results, search engines, history
and replay, model registration, `makem.sh`, Makefile, CI and documentation.
Traced surrounding UI and native execution owners and process cancellation.

Applied all three calibrated prompts verbatim; the explicit review-only
assignment delegates corrections to the integration owner:

1. "Carefully read over all of the new code you just wrote and other existing code you just modified with 'fresh eyes' looking super carefully for any obvious bugs, errors, problems, issues, confusion, etc. Carefully fix anything you uncover."
2. "Sort of randomly explore the code files in this project, choosing code files to deeply investigate and trace their functionality and execution flows through the related code files which they import or which they are imported by. Once you understand the purpose of the code in the larger context of the workflows, do a super careful, methodical, and critical check with 'fresh eyes' to find any obvious bugs, problems, errors, silly mistakes. Comply with ALL rules in AGENTS.md and ensure that any code you write or revise conforms to the best practice guides referenced in AGENTS.md."
3. "Turn your attention to reviewing the code written by your fellow agents and checking for any issues, bugs, errors, problems, inefficiencies, security problems, reliability issues. Diagnose underlying root causes using first-principle analysis. Don't restrict yourself to the latest commits — cast a wider net and go super deep."

All runtime invocations explicitly loaded `test/ogent-test-helper.el` first,
which excludes project bytecode and protects real stores. Emacs 30.2 and 29.1
ran in `ogent-fixes` and `ogent-fixes-29`. Search probes used real GNU
grep/xargs and real ripgrep at `/tmp/ogent-test-rg`; executable lookup only
selects the engine. No provider requests or authentication were used. The
reviewed SHA stayed fixed and both production-diff records are empty.

## Findings

1. **P2: supported hash-table arguments remain live through approval and batch
   preflight.**

   `lisp/ogent-tool-contract.el` explicitly accepts hash tables for `object`
   arguments. However, `lisp/ogent-tool-execution.el:92` copies only strings,
   conses and vectors; a hash table falls through at line 98 and retains
   caller ownership. Both model wrappers and the batch rely on this copier.

   The independent fixture declares an ordinary `object` argument and a
   confirmation requirement. The real approval boundary receives an object
   whose `path` value is `"safe"`. During the prompt, the caller-owned original
   table changes that entry to `"changed"`. Both text and JSON wrappers then
   execute with `"changed"`, despite their approval input initially containing
   `"safe"`. No registry changes are involved. A separate read-only batch
   reproduces the same drift: its first read changes the original object for
   its second read, and the second result is `"changed"` instead of the
   preflighted `"safe"`.

   Deep-copy supported hash-table keys and values, preserving the table's
   equality semantics, so approved/preflighted contract values cannot change
   through caller-owned mutable objects. This completes the existing freezing
   contract for an already accepted standard argument type. Evidence:
   `evidence/pass_3/review_round4/independent-probe.el`; `OBJECT PREVIEW`,
   `OBJECT EXECUTION` and `BATCH OBJECT EXECUTION` records in the Emacs 30 and
   Emacs 29 stdout transcripts.

2. **P2: ripgrep prefiltering silently loses Unicode wildcard matches.**

   The shared filename matcher at `lisp/ogent-tool-process.el:262` uses the
   component matcher, which applies Emacs character wildcard semantics.
   However, lines 523–525 also send the public filter to ripgrep. Ripgrep's
   filename wildcard matching treats `?` and character classes by bytes, so
   it can exclude valid Unicode candidates before the common postfilter sees
   any events. The translation at line 286 does not address this mismatch.

   Create a UTF-8 filename `é.txt` containing `needle`. A directory search
   with `glob_filter="?.txt"` includes that file through GNU grep but omits it
   through real ripgrep. The valid negative class `[!a].txt` does the same.
   Both engines report success and complete counts, making the missed file a
   silent false negative. The result reproduces on both Emacs versions. The
   ordinary component, recursive, brace-literal, leading-exclamation-literal,
   backslash-literal and bracket-literal filters in the same fixture agree.

   Ensure the ripgrep candidate prefilter never excludes a candidate admitted
   by the common character matcher, or construct one exact candidate set for
   both engines. Retain exact common filtering and binary handling. Evidence:
   `independent-probe.el` and the `GLOB PARITY "?.txt"` / `GLOB PARITY
   "[!a].txt"` records in both stdout transcripts. These use valid Unicode
   filenames and ordinary documented wildcards, not unsupported raw bytes or
   regular-expression dialect differences.

## Verification and non-findings

- Emacs 30 focused SDK/process/debug suites: **180 tests, 180 expected, zero
  unexpected**, with real ripgrep available. `focused-ert-30.out` preserves
  the complete transcript.
- Emacs 29 focused SDK/process/debug suites: **180 tests, 180 expected, zero
  unexpected**, with real ripgrep available. `focused-ert-29.out` preserves
  the complete transcript.
- Actual isolated `make test-build-report` fixture: **all real-runner checks
  passed**, including compiler/ERT locations, failures, Make integration,
  bootstrap errors, Unicode output and cancellation. Transcript:
  `makem-real-fixture-30.out`. This did not run repository-wide compilation,
  lint or tests, which remain the integration owner's final checks.
- The previous batch call-name mutation fixture now executes `second-read`
  and records **zero write runs**. The earlier in-place registry mutation
  fixture refuses both text and JSON replacements and rejects the changed
  second batch entry. Transcripts: `previous-flow-30.stdout` and
  `previous-registry-30.stdout`.
- Earlier repairs for raw-byte filename errors and exactly-once callback
  delivery, smaller read defaults, absolute continuations, structured history
  replay and failed-process history remain present and pass. The replayed
  previous flow fixture confirms these behaviors directly.
- The common `src/*.txt` and `src/**/*.txt` rules now agree across GNU and
  ripgrep in the independent fixture. The two findings above concern additional
  supported mutable objects and Unicode wildcard matching, not the already
  repaired call-name/component cases.

## Staging integration hazard

`makem.sh` discovers every tracked `.el` using `git ls-files` and does not
exclude the audit workspace. Current untracked evidence contains copied
baseline source/test trees under `scorerA/baseline_sources` and
`scorerB/baseline-source`. Staging those trees would add old production modules
and duplicate ERT suites to subsequent compile/lint/test discovery. The audit
workspace ignore file currently preserves evidence generally. The integration
owner confirmed this hazard will be handled by safe artifact selection or
archiving before staging and final native checks. This is a handoff integration
note about pending artifacts, not a third defect in the frozen production SHA.

This round does not count toward the required two consecutive clean rounds.
Later production corrections require a new frozen-source review; they are not
certified by this report.
