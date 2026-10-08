# Pass 1 rubric reconciliation

Target: `72016bb66928a20a49238266645abde583fa595d`. Rubric:
`sha256:44e7c00b3dee6be38118f1f40719d814278cb129f9aad34572e0936104b135a4`.
The eight tiebreaker files in `audit/partial/scores_pass1_*_scorertiebreaker.jsonl`
contain all eleven dimensions, as requested by the audit owner. Independent
review used prior evidence/notes, the original source, and fresh baseline probes;
prior score values were not read. Production files and tests were not modified.

The CLI anchors are interpreted through
`references/methodology/DSL-AND-SDK-AUDIT.md`: SDK ergonomics evaluates native
one-call workflows, parseability evaluates native return values, error pedagogy
evaluates typed failure outcomes and useful correction text, and composability
evaluates standard Lisp values/process callbacks. CLI parser and output-flag
requirements are not invented for a function without that surface. Existing
native ERT/golden/CI coverage counts; the Pass 1 zero-test assumption does not
erase tests already present. The default arithmetic mean and equal dimension
weights are retained. No post-hoc numerical risk multiplier is introduced.

| Surface/dimension | Chosen anchor | Applicability decision and original evidence |
|---|---:|---|
| `sdk_method__doctor__run` / intent | 1000, n/a | Canonical no-argument diagnostic call, with one optional opt-in boolean; no name/argument spelling or ordering decoder. Original `lisp/ogent-doctor.el:595`. Check-crash containment measures error pedagogy. |
| `sdk_method__doctor__batch` / intent | 1000, n/a | Same absence of an intent decoder. Native batch/exit contract is documented at original `lisp/ogent-doctor.el:723`; zero-argument call works. |
| `sdk_method__tools__bash` / safety | 0, applicable to direct private call | Original `lisp/ogent-tools.el:557` spawns arbitrary shell commands without a function-level gate, dry-run or rollback. Agent-runtime approval is a separate surface at `lisp/ogent-tool-execution.el:34`. |
| `sdk_method__tools__bash-async` / safety | 0, applicable to direct private call | Original `lisp/ogent-tools.el:648` has the same private-entry trust boundary. Async process cancellation is not command rollback. |
| Both raw bash methods / intent | 1000, n/a | No SDK alternative-name/option decoder exists. Shell `COMMAND` typos belong to shell-language semantics, and parameter type/presence correction belongs to error pedagogy. Registry aliases, if present, belong to registry surfaces. |
| `sdk_method__tools__bash-async` / error pedagogy | 250 | Actual timeout callback names the failure, `Timeout after 0.0s`, but offers no recovery or typed timeout/validation discriminator. Invalid timeout produces generic type text. Structured event tags alone do not satisfy useful error pedagogy. |
| `verb__make__clean` / safety | 1000, n/a | Original `Makefile:89` deletes only regenerable `lisp/**/*.elc`; it preserves source `.el` files. A mutation marker alone does not imply an irreversible operation. |
| `verb__make__compile` / safety | 1000, n/a | Original `Makefile:84` delegates bytecode generation. No irreversible user-data operation is present in the default recipe. Optional dependency installation is separately explicit. |
| `verb__make__recompile` / safety | 1000, n/a | Original `Makefile:93` cleans and attempts to rebuild bytecode. Swallowed compiler failure belongs to parseability/error/composability; bytecode remains regenerable. |
| `verb__make__offline-test` / parseability | 100 | Fresh missing-prerequisite run exits nonzero but puts a variable-path Lisp stack trace on stdout and diagnostics on stderr. Original `test/offline/boot.el.in:10`; no stable result schema. A `make -n` command string is not runtime result evidence. |

The original spreads of at least 500 on doctor intent, raw bash safety and
recompile safety were applicability/surface-boundary disagreements, not two
plausible judgments of the same anchor. They are resolved by the SDK extension
and irreversible-operation definition above, with corresponding correction
requests to scorers A/B. Averaging those incompatible interpretations would
produce meaningless intermediate scores. The narrower async error disagreement
is resolved at the actual 250 failure-message anchor, independently of prior
numbers.

The zero safety score for an explicitly inventoried **private** bash function is
confined to direct trusted SDK use. The normal agent entry is already gated by
the execution wrapper and `ogent-tool-approval-check` (`lisp/ogent-tool-approval.el:162`);
the bash registry also has `:confirm t` at `lisp/ogent-tools.el:876`. This review
does not assert a new external approval bypass or prescribe a duplicate gate.
Documentation should identify the trust boundary and direct callers should use
the policy owner when they need agent execution policy. These scores are scoped
qualitative diagnostics, not a product-readiness or security certification.

## Reproducible evidence and limits

`audit/partial/tiebreaker-baseline/` was extracted with `git archive` from the
recorded SHA. Fresh Docker probes explicitly load this original Lisp source,
even while production changes proceed. `audit/partial/tiebreaker_probe.el` and
`tiebreaker_runtime.jsonl` show identical repeated doctor fixtures, typed native
results, excluded opt-in checks, ordinary bash events, and malformed-timeout
behavior. The latter can emit both `(error "Wrong type argument: ...")` and
`(done 0)` because validation occurs after process creation. This finding was
sent to the implementation owner; it does not imply an approval-policy failure.

`tiebreaker_make_probe.py` and `tiebreaker_make_runtime.jsonl` use an isolated
generated-artifact fixture. A fake compiler exit 23 is swallowed by original
recompile, which prints success and exits 0; ordinary compile forwards the
injected failure with Make exit 2. These observations prove wrapper failure
handling, not successful real compilation. The original offline runner was
invoked without `OGENT_ELPA_DIR`, with only its local loopback fixture and
temporary directory; it exits 2 with a raw prerequisite stack trace. No provider
calls or real user-store writes were performed. Existing CI matrix and ERT
coverage were inspected at the original SHA; no complete successful baseline
suite execution is newly claimed by this reviewer.

## Clarifications for future scorers

RN-001: Add explicit n/a guidance for direct positional SDK functions that expose
no alternate-name/argument-spelling decoder. Keep SDK registry name aliases and
parameter validation separate from CLI typo/order recovery.

RN-002: Define safety applicability by irreversible user-state effects, rather
than `mutates:true` alone. Regenerable artifact deletion and misleading success
after compiler failure should not be scored as irreversible user-data loss.

RN-003: Identify the entry-point trust boundary before scoring private SDK safety.
Record the agent-runtime gate separately, preserve default weighting, and avoid
turning absence of a private helper gate into a claimed external vulnerability.

RN-004: For test/build wrappers, distinguish the useful machine exit signal from
the human diagnostic stream. Score actual runtime failure output; do not use a
dry-run recipe string as proof of a machine result contract.
