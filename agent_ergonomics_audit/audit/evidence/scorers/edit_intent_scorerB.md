# Scorer B: paired raw-edit intent applicability

I choose **intent_inference1000, n/a in both snapshots** for the inventoried private positional `ogent-tool--edit-file` method. This corrects applicability; it is not an implementation improvement.

The SDK extension maps intent inference to method aliases for common alternatives. This surface accepts a file path, literal old text, literal new text, and optional replace-all boolean. Both baseline (`72016bb`, `lisp/ogent-tools.el:787`) and final (`2401f03`, `lisp/ogent-tools.el:935`) are direct positional implementations, without an alternate method-name or named-argument spelling decoder. The previously settled private raw-bash boundary therefore applies to raw edit as well. Registry aliases and named-key typo recovery belong to other inventoried surfaces. Rejecting empty/ambiguous old context teaches parameter correction and prevents mistaken writes; those behaviors remain credited under error pedagogy and safety, not counted as a new method-name decoder.

I scored baseline and post independently before this reconciliation. For this narrow applicability review I read the specifically requested scorer A rationale document and durable post reconciliation; I did not consult A scorecard JSONL files or amend scores to match another scorer. The SDK meaning and established paired private-helper boundary determine this decision. This review settles only raw edit; all other B scores remain unchanged.

Exact original complete B records were preserved before mutation in `edit_intent_scorerB_pass1_before.jsonl` and `edit_intent_scorerB_pass2_before.jsonl`. Only the intent dimension, its evidence/notes, and arithmetic mean changed:

| State | Original intent | Corrected intent | Original mean | Corrected mean |
|---|---:|---:|---:|---:|
| Baseline | 0 | 1000, n/a | 313.636364 | 404.545455 |
| Post | 0 | 1000, n/a | 622.727273 | 713.636364 |

The correction adds the same1000/11 to each mean, preserving B's paired surface improvement. Error-pedagogy, safety, every other dimension, original runtime transcripts, production source, tests, rubric weights and triangulation archives are unchanged. These remain same-model qualitative peer measurements, not an independent security certification.

## Final root rubric decision supersedes interim n/a

The audit owner reviewed the complete SDK extension and settled dimension6 literally: **“Method aliases for common alternatives?”** This is applicable to the native raw callable even when it lacks an argument/name decoder. Its private boundary prevents borrowing registry alias gains; it does not erase the alias criterion. Fresh paired probes in `reconciliation_post/edit_intent_runtime.jsonl:1` and `:4` show `edit_file`, `edit-fiel` and `patch-file` signaling `void-function` in both states.

Accordingly I restore intent0 in both snapshots, consistent with my original independent assessment. The prior n/a decision was an interim calibration interpretation; the raw-bash historical exception remains narrow and is not generalized. Exact complete interim amended rows remain in `edit_intent_scorerB_pass1_interim_na.jsonl` and `edit_intent_scorerB_pass2_interim_na.jsonl`; original pre-amendment archives remain untouched. Only intent/evidence/notes and arithmetic means changed. Final B raw-edit means are baseline313.636364 and post622.727273; paired uplift is unchanged309.090909.
