# Pass 2 reconciliation and paired regression investigation

Baseline: `72016bb66928a20a49238266645abde583fa595d`. Runtime/source probes:
`b0945bf14de3622af607f6a2e83ffa245cf091c8`. Final production freeze:
`2401f03bc5d7cd0f2915b88aede9a4444407e2b4`. The final freeze only adjusts an
unrelated doctor docstring/test; the five scored production sources have an
empty diff from the probed SHA. The shared native test file only adds a doctor
docstring assertion; edit/make/offline assertions are unchanged. Rubric:
`sha256:44e7c00b3dee6be38118f1f40719d814278cb129f9aad34572e0936104b135a4`.

Five independent post tiebreaker files contain all eleven integer dimensions,
in 50-point increments, in `audit/partial/scores_pass2_*_scorertiebreaker.jsonl`.
The initial independent review inspected prior evidence and notes while
excluding raw values from that read. The owner supplied disputed values and
apparent aggregate regressions in the task description; those numbers did not
determine the initial scores. The final disclosed calibration read the historical
baseline third record to preserve its exact bytes and describe the one changed
score. Fresh source/runtime evidence determines the anchors.
Default arithmetic-mean weighting remains unchanged.

## Chosen applicability and anchors

| Surface / dimension | Decision | Paired evidence and reason |
|---|---:|---|
| Raw `ogent-tool--edit-file` / safety | 0, applicable | A valid direct call still overwrites immediately, without a helper-level approval gate, preview or rollback. `edit_runtime.jsonl:20` shows the registered wrapper denying and preserving bytes; rows22/23 show the raw call writing under the same denied policy. This is the same private-function boundary used for baseline raw bash methods. |
| Raw edit / error pedagogy | 750 | Rows11/13 show typed `user-error` with occurrence count and exact unique-context/`replace_all true` correction. Rows16/17 name `read_file` for missing/empty context. Baseline row8 had only generic `error` and no recovery instruction. |
| Raw edit / intent | 0, applicable | Corrected after focused review of the SDK criterion “Method aliases for common alternatives?”. `edit_intent_runtime.jsonl` rows1–6 show direct underscore spelling, edit-fiel typo and patch-file alternative yielding identical generic `void-function` failures in both states. Registry recovery remains separate; validation is not method-name recovery. See the explicit correction appendix below. |
| `make clean` / parseability | 250 | Baseline rows2/3 and post rows11/12 have the identical `Removed all .elc files\n`, empty stderr and status0. The old third reviewer explicitly credited a stable line/basic Make exit at this low build-wrapper anchor; post adds test-bytecode coverage without changing that result contract. |
| `make compile` / parseability | 250 | Actual unchanged makem was invoked in both snapshots, with a fake Emacs that writes no bytecode. Baseline row4 and post row13 return Make2, put the same compiler diagnostic on stdout and human ANSI/timestamp logs on stderr. The selected Emacs is now honored. Output gained no machine result schema and lost no existing one. |
| `make compile` and `make recompile` / composability | 250 | Actual makem under non-TTY `NO_COLOR=1 CI=true TERM=dumb` preserves nonzero failure status but copies the compiler diagnostic to stdout and prints colored timestamped logs to stderr. A replaced makem stub with plain stderr verifies recipe propagation only and cannot establish actual logger behavior. |
| `make clean`, `make compile`, `make recompile` / safety | 1000, n/a | Applies to regenerable bytecode only, consistently with Pass 1 reconciliation. Both cleanup fixtures preserve source `.el`; no irreversible user-data operation requires a gate. |
| `make offline-test` / safety | 1000, n/a | Baseline and post use temporary fixture/store roots, cleanup traps and guarded loopback transport. These mechanisms are unchanged by added preflight. The relevant applicability is fixture isolation, rather than presence of mutation metadata or absence of a generic CLI confirmation flag. |

All runtime references in this table are relative to
`audit/evidence/reconciliation_post/`: `make_runtime.jsonl` or
`edit_runtime.jsonl` as indicated.

The clean/compile 250 parseability decisions preserve the explicit earlier
build-wrapper adaptation: the stable basic process status earns partial credit
while unstructured human output remains far below a complete JSON result
contract. They do **not** assert the rubric's literal “some verbs have JSON”
example for these Make targets. This adaptation applies equally to baseline and
post. A future stricter literal-JSON interpretation must rescore **both** states
and identify the resulting calibration change; applying it only after the
implementation would fabricate a regression. No rubric file, default weight,
or production source was edited by this reviewer. One explicit baseline
composability calibration was later amended; its exact archived history and
changed fields are recorded in the appendix below.

## Apparent decreases versus observed behavior

The owner's clean parseability 250→125, compile parseability 250→175 and offline
safety 1000→875 alerts compare baseline medians with a third reviewer against
post medians with only two reviewers. Independent third post observations now
exist for those same surfaces. Their decisive paired contracts are unchanged,
so these alerts are reviewer-composition/applicability drift rather than
observed functional regressions. The owner should regenerate the medians from
all present post partials and retain the original confidence spreads. Merely
setting a third score cannot erase disagreement or make high unsupported
composability evidence valid.

The edit improvement is real: baseline ambiguous default edits produce
`new same`, and baseline `:json-false` accidentally replaces both occurrences.
Post rejects both before writing and preserves `same same`. Empty/malformed
arguments are rejected promptly. That prevention and teaching credit belongs
to error pedagogy, intuitiveness, and regression coverage; it does not turn the
raw trusted helper into an approval/rollback owner. The new handbook at
`lisp/ogent-agent.el:110` correctly directs policy-sensitive callers to registered
execution wrappers. No external approval bypass is asserted.

Recompile's failure handling is also a real improvement. Baseline row5 swallows
the fake compiler's exit23, reports `Recompiled all .el files`, and exits0.
Post row14 recursively uses standard compile, keeps its diagnostic and returns2.
The inherited makem stream/color/timestamp limitations remain. Those actual
limitations are recorded at low composability/parseability anchors rather than
hidden by the simpler native failure stub.

Offline prerequisite failure changes from a raw stdout Lisp stack trace
(baseline row19) to empty stdout and an exact environment assignment/retry on
stderr (post rows20/21). Both post invocations produce identical preflight
bytes. That verifies the preflight improvement; it does not establish complete
successful ERT output determinism or a JSON test report. Full suite timing and
fixture scheduling remain volatile, so determinism retains a low score.

## Evidence, replay and limits

`probe_make.py` copies exact snapshot Makefiles and unchanged makem into
temporary fixtures. An isolated git index supplies makem's tracked-file
discovery prerequisite without a commit. Compiler processes are synthetic:
they expose executable selection and print a controlled failure, while writing
no actual bytecode. Synthetic `.elc` marker files let clean scope be inspected.
No shared production cleanup/compilation was performed. The initial unindexed
fixture failed before compiler discovery; its transcript is retained separately
as `make_runtime_initial.jsonl` and is not decisive compiler evidence.

`probe_edit.el` explicitly loads original baseline source, saves/restores the
post function, and uses test-helper-provisioned temporary files. It resets the
same input file between repeated success calls, records before/after contents,
and checks raw versus registered policy boundaries. It does not run the known
baseline empty-context infinite loop again.

The source-only focused native replay passed all nine edit/make/offline
regressions. `focused_ert.stderr:121` records `9 results as expected, 0
unexpected`; representative assertions are in
`test/ogent-agent-ergonomics-tests.el:100`, `:348`, `:359`, and `:457` at the
final freeze (the latter three were three lines earlier at the probe SHA).
Existing native CI loads all tests and maintains the Emacs29.1/30.2 ×
minimum/current-gptel offline matrix. This reviewer does not newly claim a full
successful compilation or dependency matrix replay. No provider login,
inference, source edits, bytecode generation or git commits were performed.

## Future rubric clarifications

RN-005: Add a build/test-wrapper parseability anchor distinguishing a stable
process exit plus human diagnostics from a JSON result schema. Keep wrapper
fixture proof separate from actual delegated logger behavior.

RN-006: In paired measurements, retain consistent scorer coverage or explicitly
classify median changes caused solely by a missing third reviewer. Preserve
confidence spreads and record calibration amendments rather than silently
changing applicability only in the post state.

RN-007: For raw SDK mutators, distinguish preflight validation from an approval,
preview, rollback or idempotency mechanism. Cite the registered policy owner
separately and apply the same trust boundary to both snapshots.

## Appendix: explicit final paired-calibration correction

The initial independent post edit intent score was 1000/n/a. That applied the
earlier raw-bash reconciliation to another positional private helper without
examining the SDK rubric's specific “Method aliases for common alternatives?”
criterion. Baseline edit had no corresponding third-review applicability
decision. The SDK criterion is applicable to the edit method: absence of a CLI
option parser removes CLI flag/order requirements, but does not by itself
remove native method-name alias/recovery expectations. The general n/a
extension was therefore overbroad for this surface.

A fresh paired direct-name probe now records generic `void-function` for
`ogent-tool--edit_file`, `ogent-tool--edit-fiel`, and
`ogent-tool--patch-file` in both states, without calling a real mutator. The
post edit intent score changes **1000→0** and is applicable, matching the same
absence of direct recovery in baseline. All other ten post edit dimensions are
unchanged; its tiebreaker mean changes **645.454545→554.545455**. No improvement
in method-name intent is claimed from new context/type error messages or
registry aliases. The owner preserved all original independent post rows under
`audit/triangulation/post/` before this correction. Raw-bash n/a remains its
historical, narrowly recorded reconciliation; extending it to other SDK
methods requires its own explicit applicability review. RN-001 should be
refined accordingly rather than treated as a universal positional-SDK rule.

Baseline compile composability had been scored500 by the historical third
reviewer even though its notes already identified default colors and absent
NO_COLOR handling. The score overcredited the 500 anchor, which explicitly
requires NO_COLOR and stream compatibility. The former runtime stub replaced
makem and therefore proved failure forwarding, not the delegated logger's
actual behavior. Fresh paired evidence invokes the **actual baseline makem**
with a fake Emacs under non-TTY `NO_COLOR=1 CI=true TERM=dumb`:
`make_runtime.jsonl:4` shows status2, the controlled compiler diagnostic on
stdout, and ANSI/timestamp log messages on stderr. Post row13 has the same
stream contract; only the selected executable changes. Composability250 is
the same partial-scripting anchor for both states.

Before changing that baseline partial, its entire original byte sequence was
saved as
`audit/triangulation/baseline_pre_paired_calibration/scores_pass1_verb__make__compile_scorertiebreaker.jsonl`.
`recalibration_manifest.json` in that directory records original and active
SHA256 digests and every changed field. The active baseline third partial
changes only **composability500→250** among scores; the other ten historical
dimensions remain intact. Its arithmetic mean changes **445.45→422.727273**.
The composability evidence is replaced with the fresh actual-makem transcript,
an explicit baseline target SHA is added, and notes explain the amendment.

This baseline change is a disclosed correction of historical anchor
calibration, not a production regression or an attempt to erase the previous
assessment. The original baseline aggregate may remain500 if the other
historical baseline reviewers still carry higher values: median aggregation
cannot make an incompatible 500/750 interpretation valid merely because a
third reviewer has corrected theirs. The owner should reconcile those prior
baseline interpretations against the same actual delegated evidence, preserve
their original rows before any amendment, and distinguish original-history
metrics from recalibrated paired metrics. This reviewer did not edit their
rows or the historical scorecard.
