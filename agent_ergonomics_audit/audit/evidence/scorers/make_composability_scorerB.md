# Scorer B: actual delegated Make composability

I reevaluated only compile/recompile composability using actual delegated makem evidence, not another scorer's raw score file. The unchanged real makem failure probes at `reconciliation_post/make_runtime.jsonl:4`, `:13`, and `:14` demonstrate compiler prose on stdout and ANSI/timestamp logs on stderr under non-TTY NO_COLOR/CI/TERM controls. My original post probe substituted a plain-stderr compiler/makem stub: it established recipe failure propagation and EMACS forwarding but did not establish actual delegated logger behavior. Baseline compile500 and post compile/recompile700 overcredited that boundary.

I choose compile250 in both states and post recompile250: they retain useful native nonzero status but fail the rubric's color/stream composability controls. I retain baseline recompile0, because row5 confirms it suppresses compiler errors and returns0 with false success. That separate automation defect is worse than the inherited logger limitation and is fixed by the implementation; it should not be averaged away as though baseline recompile delegated to makem.

Exact complete original records are archived as `make_composability_scorerB_passN_<target>_before.jsonl`. Only this dimension, corresponding evidence/notes and arithmetic means changed:

| State / target | Original composition | Final composition | Original mean | Final mean |
|---|---:|---:|---:|---:|
| Baseline / compile | 500 | 250 | 495.454545 | 472.727273 |
| Post / compile | 700 | 250 | 627.272727 | 586.363636 |
| Baseline / recompile | 0 | 0 | 263.636364 | 263.636364 |
| Post / recompile | 700 | 250 | 627.272727 | 586.363636 |

No unrelated dimensions, production source, tests, other partials, original runtime evidence, or rubric weights changed. These corrections preserve the observed recompile false-success repair while removing unsupported credit for NO_COLOR/diagnostic stream behavior.
