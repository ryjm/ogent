# Phase 7 fresh-eyes review

The review follows the three calibrated review modes below on `master`.
The root agent owns all production edits and commits. This reviewer writes
evidence and reports findings without changing source or bytecode. The target
is an Emacs Lisp SDK; existing text tool results remain supported.

**Prompt 1 (verbatim).** Carefully read over all of the new code you just wrote and other existing code you just modified with 'fresh eyes' looking super carefully for any obvious bugs, errors, problems, issues, confusion, etc. Carefully fix anything you uncover.

**Prompt 2 (verbatim).** Sort of randomly explore the code files in this project, choosing code files to deeply investigate and trace their functionality and execution flows through the related code files which they import or which they are imported by. Once you understand the purpose of the code in the larger context of the workflows, do a super careful, methodical, and critical check with 'fresh eyes' to find any obvious bugs, problems, errors, silly mistakes. Comply with ALL rules in AGENTS.md and ensure that any code you write or revise conforms to the best practice guides referenced in AGENTS.md.

**Prompt 3 (verbatim).** Turn your attention to reviewing the code written by your fellow agents and checking for any issues, bugs, errors, problems, inefficiencies, security problems, reliability issues. Diagnose underlying root causes using first-principle analysis. Don't restrict yourself to the latest commits — cast a wider net and go super deep.

## Round 1

**Source.** Baseline `72016bb66928a20a49238266645abde583fa595d` through
`fe75a37`, with root's known approval-alias followup subsequently committed
as `2064527`. All three review modes above were applied.

**Coverage.** Read `AGENTS.md`, `specs/style-guide.org`, relevant architecture
and gptel integration specifications, every changed Lisp file, Makefile,
regression selectors and their ERT harness. Traced registration and gptel
wrappers through approval, argument extraction, UI edit proposals, acceptance,
MCP serialization, and synchronous/asynchronous process completion.

**Findings.** 2 substantive findings; 0 trivial findings.

1. Default diff-block previews did not enforce the new edit uniqueness and
   nonempty match contract. An edit of `same\nsame\n` with explicit false
   produced a diff replacing both occurrences; accepting it returned
   `Tool error: edit_file old_string matches 2 occurrences...` while setting
   `:status applied`, leaving the file unchanged. Empty old strings also
   produced a proposed diff. There is **no claim of a default-preview hang**.
   Evidence: `audit/evidence/review/round1-probe.el` and
   `audit/evidence/review/round1-probe-emacs30.log`. The original async
   polling experiment was stopped before completion; the independent bounded
   followup below validates process completion.
2. Shared boolean normalization changed MCP explicit `:json-false` to `nil`.
   The MCP wrapper omitted optional nil values and serialized required nil as
   JSON null, so explicit false lost its external meaning. The caller trace
   connected `ogent-tool-contract-validate-values`,
   `ogent-tool-execution-wrapper`, the generated MCP wrapper, and
   `ogent-mcp--args-to-alist`. Existing actual-dependency offline coverage
   exercises optional false/null/nested payload values.

**Substantive fixes (root).**

- `aab697e`: validate default edit previews, keep failed single/bulk acceptance
  in an error state with retry, preserve MCP false independently of omission,
  and validate standard gptel symbol types.
- `780af28`: keep reviewed absolute file targets stable through acceptance,
  resolve inline project paths consistently, classify denial/unavailability
  results as errors, and satisfy native lint requirements.

**Verdict.** NOT_CLEAN.

## Round 2

**Source.** Frozen candidate `780af28`. All three review modes above were
applied again, with emphasis on custom registry/MCP contracts and the repaired
preview/accept flow.

**Findings.** 1 substantive finding; 0 trivial findings.

- Exact hyphenated argument names in custom or MCP specs cannot execute.
  `ogent-tool-contract--key-name` converts an exact key such as `:file-path`
  to `file_path`, then compares it with the untouched declared name
  `file-path`. A real Emacs probe returns the self-contradictory correction
  `custom has no argument :file-path; did you mean file-path? use declared
  arguments ("file-path")`. The positional wrapper also constructs
  `:file-path` before the second named validation, so the failure affects
  normal execution, not only direct calls to a helper.
  Evidence: `audit/evidence/review/round2-hyphen-argument-780af28.log`.

**Substantive fix (root).** `2ee1692`: prefer an exact declared argument
spelling; accept hyphen/underscore aliases only when they identify a unique
declared argument. Preserve the declared external spelling when constructing
arguments, including schemas declaring both variants.

**Verification of prior repairs.** A bounded real Emacs 30.2 probe rejects
ambiguous and empty default previews; single and bulk acceptance of a file
changed after review stay in an error state. MCP optional explicit false,
required nil-as-false, JSON null, and nested objects serialize correctly;
omitted optional fields produce `{}`. Discovery does not claim colliding
aliases. Three grep and three shell probes each deliver all output before
exactly one terminal callback. Evidence:
`audit/evidence/review/verification-probe.el` and
`audit/evidence/review/verification-emacs30-780af28.log`.

**Verdict.** NOT_CLEAN.

## Round 3

**Source.** Frozen candidate `2ee1692`. All three review modes above were
applied again, including the wider-net peer review of exact-edit safety.

**Findings.** 1 substantive finding; 0 trivial findings.

- Edit occurrence searches and replacement inherit `case-fold-search=t`, so
  the declared exact `old_string` contract is not case-sensitive. A real
  Emacs probe creates `lowercase\n`, calls `ogent-tool--edit-file` with
  `old_string="LOWERCASE"`, and successfully changes it to `CHANGED`.
  The same inherited setting affects default diff counting/replacement and
  inline occurrence searches. It also treats differently cased neighbors as
  duplicate exact matches. Evidence:
  `audit/evidence/review/round3-case-fold-2ee1692.log`.

**Substantive fix (root).** `f37e561`: bind `case-fold-search` to nil for
direct edits, default diff generation, inline occurrence search, and recursive
glob matching. Verify mismatched case cannot edit, exact case remains unique
beside differently cased text, and recursive glob respects pattern case.

**Verdict.** NOT_CLEAN.

## Round 4

**Source.** Frozen `f37e561db90a1d854d7aa5615c4c30d83d170543` on `master`.
All three calibrated review modes above were applied again.

**Coverage.** Re-read final changes in tool argument validation, exact-name
resolution, wrapper metadata/closure handling, MCP serialization, direct and
reviewed edits, approval policy, doctor/discovery reports, Makefile, offline
prerequisite handling, and the regression replay harness. Traced the repaired
flows to their registered execution paths and reviewed relevant callers and
tests, including custom declared names and case-sensitive edit context.

**Findings.** 0 total; 0 trivial; 0 substantive.

**Verification.** Independent bounded Emacs 30.2 probes pass for ambiguous
and empty edit rejection, unchanged error status after single/bulk acceptance
failure, optional false versus omission, required false, null and nested MCP
payloads, discovery alias collisions, full process output before one final
terminal callback, exact/alias/distinct argument names, and case-sensitive
direct/default/inline edit behavior. All 35 ergonomics ERT tests pass.

Evidence:

- `audit/evidence/review/final-probe.el`
- `audit/evidence/review/verification-probe.el`
- `audit/evidence/review/round4-final-probe-emacs30-f37e561.log`
- `audit/evidence/review/round4-focused-ert-emacs30-f37e561.log`

**Substantive fixes.** None.

**Verdict.** CLEAN.

## Round 5

**Source.** The same frozen `f37e561db90a1d854d7aa5615c4c30d83d170543`.
All three calibrated review modes above were applied again, with particular
attention to cross-version process delivery, external JSON values, stale
registry objects, exact approval aliases, and reviewed edit target ownership.

**Findings.** 0 total; 0 trivial; 0 substantive.

**Verification.** The independent final probes also pass on real Emacs 29.1:
all covered JSON, approval metadata, exact argument/edit contracts and process
completion behaviors agree with Emacs 30.2. The full focused ergonomics ERT
selector passes 35/35 on Emacs 29.1. Rechecked the doctor 0/1/2 mapping, no
opt-in diagnostics in discovery/triage, error classification and retry states,
absolute reviewed file targets, and build/regression exit propagation.

Evidence:

- `audit/evidence/review/round5-final-probe-emacs29-f37e561.log`
- `audit/evidence/review/round5-focused-ert-emacs29-f37e561.log`

**Substantive fixes.** None.

**Verdict.** CLEAN.

## Initial clean checkpoint and validation ownership

Phase 7 reached its initial clean checkpoint after 5 rounds: 4 substantive
findings across 4 root fix commits; rounds 4 and 5 are consecutively CLEAN on
`f37e561`. Root subsequently extended the review for a semantic doctor-hint
correction, so final termination is tracked in the followup rounds below.
This reviewer independently ran the final 35-test ergonomics selector and
bounded behavioral probes on both Emacs 29.1 and 30.2. No production source,
bytecode, provider credentials or external provider endpoints were changed
or used by this reviewer.

The root agent owns final native full-suite, store-integrity, lint,
actual-dependency offline, and baseline/post regression-proof reruns. Earlier
full validation passed before the last two review fixes; consult the final
root verification artifacts for checks tied to the final source commit.

## Round 6

**Source.** `b0945bf14de3622af607f6a2e83ffa245cf091c8`. Root changed the
doctor invalid-format error string to print a valid `'json` correction and
pinned that correction in the existing R008 test. This code-string change is
substantive under the skill definition, so root requested final followups.
All three calibrated review modes above were applied, focusing on the delta
and rechecking previously repaired critical SDK paths.

**Findings.** 1 substantive finding; 0 trivial findings.

- The public `ogent-doctor-batch` docstring retained the same invalid example.
  Its single-backslash `\='json` source escape reads as `='json`; a real
  Emacs `(documentation 'ogent-doctor-batch)` prints
  `for example (ogent-doctor-batch nil ='json).` Thus agents reading the
  public function documentation still receive an invalid call. Evidence:
  `audit/evidence/review/round6-doctor-docstring-b0945bf.log`.

**Verification completed.** The corrected error hint itself reads and
evaluates to valid JSON with exit 0 against local fixture diagnostics; invalid
formats do not run diagnostics. Both R008 tests and the critical behavioral
probes pass on Emacs 30.2 and 29.1. These passing checks do not erase the
public-documentation finding.

Evidence:

- `audit/evidence/review/round6-probes-emacs30-b0945bf.log`
- `audit/evidence/review/round6-doctor-ert-emacs30-b0945bf.log`
- `audit/evidence/review/round7-probes-emacs29-b0945bf.log`
- `audit/evidence/review/round7-doctor-ert-emacs29-b0945bf.log`

The filenames prefixed `round7` contain the independent Emacs 29 followup
verification begun before the documentation finding; they are not a clean
Round 7 verdict.

**Substantive fix (root).** `2401f03`: make the public docstring example
display `(ogent-doctor-batch nil (quote json))` and pin the actual runtime
documentation in R008. The displayed expression reads as the correct JSON
doctor call without quote-escape artifacts.

**Verdict.** NOT_CLEAN.

## Round 7

**Source.** Frozen `2401f03bc5d7cd0f2915b88aede9a4444407e2b4` on `master`.
All three calibrated review modes above were applied again, focusing on the
doctor documentation/test delta and tracing the critical registered SDK paths.

**Findings.** 0 total; 0 trivial; 0 substantive.

**Verification.** Real Emacs 30.2 runtime documentation displays the valid
`(ogent-doctor-batch nil (quote json))` example. The displayed expression reads
to the correct call. The error hint remains valid and evaluates to versioned
JSON with exit 0 against local fixture diagnostics; invalid format rejection
does not run diagnostics. Both R008 tests pass. Independent critical probes
again pass for invalid edit preview rejection, single/bulk acceptance error
states, MCP false versus omission, null/nested objects, exact declared argument
names and distinct fields, exact-case direct/default/inline edits, discovery
alias collisions, and complete process output before one terminal callback.

Evidence:

- `audit/evidence/review/doctor-hint-probe.el`
- `audit/evidence/review/final-probe.el`
- `audit/evidence/review/verification-probe.el`
- `audit/evidence/review/round7-probes-emacs30-2401f03.log`
- `audit/evidence/review/round7-doctor-ert-emacs30-2401f03.log`

**Substantive fixes.** None.

**Verdict.** CLEAN.

## Round 8

**Source.** The same frozen `2401f03bc5d7cd0f2915b88aede9a4444407e2b4`.
All three calibrated review modes above were applied again. Rechecked the
doctor call/documentation boundaries and severity mapping, argument validation
before execution, registered approval ownership, and repaired review/accept
and external serialization paths.

**Findings.** 0 total; 0 trivial; 0 substantive.

**Verification.** Real Emacs 29.1 reproduces the valid runtime docstring and
error hint, successful fixture JSON correction, no diagnostics on invalid
format, and 2/2 passing R008 tests. Every critical-contract probe listed in
Round 7 also passes on Emacs 29.1, including final output delivery and exactly
one terminal event. Source HEAD remained unchanged through both final rounds.

Evidence:

- `audit/evidence/review/round8-probes-emacs29-2401f03.log`
- `audit/evidence/review/round8-doctor-ert-emacs29-2401f03.log`

**Substantive fixes.** None.

**Verdict.** CLEAN.

## Final termination

Phase 7 review completes after 8 recorded rounds. Rounds 7 and 8 are
consecutively CLEAN on `2401f03bc5d7cd0f2915b88aede9a4444407e2b4`, with no
unresolved reviewer findings. Five substantive reviewer findings were fixed
by the root agent; the root's separately identified error-hint correction
`b0945bf` triggered the final review extension. The root owns final full-suite,
store-integrity, lint, actual-dependency offline and baseline/post proof checks.
Independent reviewer verification of the final documentation and critical
contracts passes on both Emacs 29.1 and 30.2; the earlier complete 35-test
ergonomics selector also passed on both versions before these doctor-only
corrections. No production source/tests or shared bytecode were changed by
this reviewer.
