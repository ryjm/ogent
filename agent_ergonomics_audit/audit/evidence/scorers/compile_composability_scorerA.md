# Scorer A: paired compile composability calibration

I independently amend baseline `make compile` composability from **500 to
250**. Post remains **250**. Exact original baseline record is preserved in
`compile_composability_scorerA_pass1_before.jsonl` alongside this note.

Fresh paired evidence at
`audit/evidence/reconciliation_post/make_runtime.jsonl:4` invokes actual
baseline makem in an isolated fixture with a controlled failing Emacs. It
returns Make exit2, copies `fixture compiler failed` into stdout and writes
ANSI-colored timestamped ERROR/LOG text to stderr. The probe explicitly sets
`NO_COLOR=1 CI=true TERM=dumb` (`probe_make.py:51`). These environment options
do not suppress makem's color/prose logging. A git diff of makem between
baseline `72016bb` and final production `2401f03` is empty.

My earlier baseline500 overcredited the dry-run recipe and basic process
behavior. Actual delegated logging warrants the same low250 anchor already
assigned from my own post actual-makem probe. The nonzero failure signal
remains useful, while mixed compiler prose lacks a clean machine-result stream.
Baseline compile's mean changes from **427.272727 to 404.545455**. No other
dimension, post score, production source or rubric weight changed.
