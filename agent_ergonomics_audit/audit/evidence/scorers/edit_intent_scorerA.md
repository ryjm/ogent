# Scorer A: paired raw-edit intent applicability

**Final decision: applicable, 0 in both states.** The interim n/a assessment
below is superseded by the final root rubric decision documented at the end.

I independently choose `intent_inference: 1000` with **n/a applicability for
both snapshots** of `sdk_method__tools__edit-file`. This is a correction to my
earlier applicability choice, not an implementation improvement.

The SDK extension asks whether a method has aliases for common alternatives.
This inventoried entry is the private positional function
`ogent-tool--edit-file`, not the registry name resolver or named-argument
decoder. Its baseline signature (`72016bb`, `lisp/ogent-tools.el:787`) and final
signature (`2401f03`, `lisp/ogent-tools.el:935`) both accept file path, exact old
text, new text and an optional boolean. Neither function decodes alternate
method names or argument spellings. The existing raw-bash reconciliation uses
this same private-function boundary; raw edit should receive the same
applicability treatment in both states.

Registry underscore aliases and typo suggestions belong to registry/argument
surfaces. Rejecting missing or ambiguous exact edit context belongs to error
pedagogy and safety, rather than method-name inference. The post function's
useful `read_file` and `replace_all true` corrections do not create an alternate
SDK name decoder. I retain my independent error-pedagogy scores (250 baseline,
850 post) and direct-helper safety scores (0 in both states).

Before amendment, I preserved exact complete records in
`edit_intent_scorerA_pass1_before.jsonl` and
`edit_intent_scorerA_pass2_before.jsonl` alongside this clarification. The
original triangulation archives are also untouched. Only this dimension,
its evidence/notes and the arithmetic mean changed:

| State | Original intent | Corrected intent | Original mean | Corrected mean |
|---|---:|---:|---:|---:|
| Baseline | 0 | 1000, n/a | 354.545455 | 445.454545 |
| Post | 0 | 1000, n/a | 554.545455 | 645.454545 |

The paired surface improvement remains 200 points; the correction adds the
same 1000/11 to both means. No unrelated score, production source, rubric
weight or runtime evidence was changed. I read the requested durable
reconciliation and SDK extension, but no scorer B score file. My original
scoring-generator scripts remain historical measurements; the preserved
records and this paired clarification document the subsequent correction.

## Final root rubric decision

The owner correctly points to the SDK extension's explicit dimension-six
criterion: **"Method aliases for common alternatives?"** Scoring the raw
private callable makes the absence of aliases a scored deficiency. Having no
name decoder is not a sufficient reason to mark this criterion inapplicable.
My interim n/a interpretation generalized the narrower historical raw-bash
adaptation beyond its agreed scope, and is withdrawn for raw edit.

The paired native-call transcript
`audit/evidence/reconciliation_post/edit_intent_runtime.jsonl` shows
`ogent-tool--edit_file`, `ogent-tool--edit-fiel` and `ogent-tool--patch-file`
all signal `void-function` in baseline and post. Registry alias gains remain
separate; context/uniqueness validation remains error-pedagogy credit. I restore
raw-edit intent to **0 in both states** and recompute means to **354.545455
baseline, 554.545455 post**, preserving the 200-point paired improvement.

Before restoring the score, I preserved exact interim complete rows in
`edit_intent_scorerA_pass1_interim_na.jsonl` and
`edit_intent_scorerA_pass2_interim_na.jsonl`. Original before-amendment records
and triangulation archives remain intact. No other raw-edit dimension changed.
