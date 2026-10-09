# Scorer B judgment provenance and incremental refresh

Current revalidated source target: `5d07d807bc85a093725db24e33996b4af690ec0f`.
Original independent numerical judgment target: `a2fa8ce0533b4a508fb641f343fa55b15fd6fc60`.

The runtime sections below describe retained original evidence. The final section
identifies the shared incremental checks; no new blind full reading is claimed.
Paired baseline target: `b3caf9300c7336ef812ed061158f851c5a47ccf7`.
Rubric: `sha256:44e7c00b3dee6be38118f1f40719d814278cb129f9aad34572e0936104b135a4`.

These are independent qualitative judgments by the same scorer/model using the installed JSM rubric, its DSL/SDK adjustments and IO contract. They are not task completion percentages or experimentally calibrated quality estimates. No other scorer's output or historical numerical scores was read. Applicability anchors in `rubric_reconciliation_post.md` informed scope; its old numerical judgments were not used. The paired baseline was requested to apply the same current criteria to actual old code, rather than treating historical criterion differences as product changes. Historical passes 1 and 2 were not edited.

The current original 19 rows are in `audit/partial/scores_pass4_current_scorerB.jsonl`. The six new APIs are separate in `audit/evidence/pass_3/scorerB/new_api_scores.jsonl`; absent baseline methods have no invented baseline. The paired original 19 are in `audit/evidence/pass_3/scorerB/baseline_paired_scores.jsonl`. These per-scorer rows omit aggregate/pass/time fields, which the parent owns. Every dimension above 700 has relative audit-workspace file/line evidence. `validation.json` records the independent artifact checks, and `source_hashes.json` checks the exact archived baseline bytes and current cited source bytes against their Git objects.

## Original actual runtime evidence retained from a2fa8ce

All local SDK runs used Docker container `ogent-fixes`, actual Emacs 30.2, `-Q --batch -L /work/lisp -L /work/lisp/ui -L /work/test -l /work/test/ogent-test-helper.el`, with `NO_COLOR=1`, `CI=true`, `TERM=dumb`. The helper forces source loading and protects user stores. No provider call was made. Tests and their source assertions are cited separately from independent runtime claims; scorer B did not run a broad repository compile or offline suite while shared native verification was active.

`probe.el` plus `probe_final_edges.el` produced 70 current records in `probe.stdout.jsonl`. Each record archives the invocation and returned/signalled result. The first 64 cover raw methods, registry/wrapper contracts, named pages/batches/async calls, discovery and doctor behavior. The six final records additionally verify copied mutable policy inputs, canonical/frozen later batch targets and arguments, configured default read caps, GNU component filtering, explicit-file filtering and parseable raw-byte filename rejection. The policy mutation hook is an adversarial fixture for input ownership, not evidence of real policy effectiveness. The custom declared-read extension mutates only the fixture's client data; effect classification still trusts extension metadata and is not an OS sandbox.

The image has GNU grep and no ripgrep. Independent structured-search runtime therefore covers GNU fallback, including component and explicit-file filters. Five supplemental records in `search.stdout.jsonl` from `probe_binary_selection.el` verify a match before a late NUL is excluded, UTF-16 BOM/NUL text is excluded, an ordinary file symlink is selected by its spelling, directory symlinks are not traversed, excluded invalid UTF-8 filenames remain unread, and a selected invalid filename returns parseable unsupported_output. The new selected-file subprocess branches are covered through actual GNU execution; ripgrep grouping/cancellation and argv behavior are supported by cited source tests, not claimed as scorer B runtime. Source tests for the ripgrep protocol are evidence of regression protection; scorer B does not claim its own ripgrep replay. Controlled repeat assertions are exact same-process/input comparisons. Fresh doctor processes have different protected sandbox paths; those runs are retained but do not justify cross-environment byte identity.

`probe_registry.el` loaded actual gptel source from `/tmp/gptel-minimum/gptel.el` and actual installed dependency directories under `/tmp/ogent-fixdeps/30.2/elpa`. Four records in `registry.stdout.jsonl` show a real constructed tool object, alias cache identity, native schema and enabled object names. Three additional records in `object.stdout.jsonl`, produced by `probe_object_freeze.el`, verify nested object-table input copying during policy mutation, stable real-gptel object-schema caching followed by refresh on an in-place schema change, and stale-wrapper refusal. The input fixture changes both the caller string and nested hash value; the function receives the original data. Object probes have their own current freeze marker `object.target_sha`. No replacement constructor stub earns the registry scores. Ordinary protected bootstrap metadata is sufficient for local doctor checks but does not represent a live provider environment.

`probe_build.py` copied the actual current `Makefile` and `makem.sh` into a minimal package/ERT fixture and ran 18 commands with actual Emacs. The fixture had a temporary Git index for the helper's tracked-file discovery; it had no commit, and its `.git` was removed. Thirteen commands produced independently parsed versioned JSON reports. Real compiler syntax failures and real ERT failures retained nonzero process exits and diagnostics; Make's exit 2 is distinct from helper task exit 1. The ordinary warning probes have historical names containing `warning-failure`, but ordinary compile/recompile warnings correctly exit 0. Only lint warnings are failure assertions. Both syntax failures and the ERT failure are genuine compiler/test executions, not replacement-helper output. Clean preserved source and removed both bytecode files. Offline runtime only replayed missing-prerequisite refusal; no broad offline success is claimed.

Four additional records in ledger.stdout.jsonl, produced by probe_ledger_recovery.el, use actual ledger file writes. A writable ledger path permits start, then the executed fixture function renames that original captured file to a .started file and creates a directory at the original filename. Completion therefore fails with real file I/O at the captured destination; changing ambient configuration is no longer used to inject the failure. SDK synchronous completion retains the completed mutation/result and returns ledger_write_failed with exact writable-ledger and do-not-rerun guidance. An immediate custom async tool returns a non-process string and calls completion twice; the SDK returns nil, delivers once, preserves data and nests the original tool error inside the ledger failure. Legacy UI retains completed bytes and a visible warning. A directory ledger path before start prevents execution and delivers one typed terminal error. Fixture names use the existing explicit allow-list; no policy mock or provider request supplies these results. These recovery improvements strengthen the existing wrapper/call/async evidence without changing the qualitative score bands; raw mutator safety receives no inherited credit.

Three independent records in context.stdout.jsonl from probe_ledger_context.el verify relative destination capture through a real project switch. The native SDK call keeps both events in project A, retains caller changes to project B and future ledger settings, leaves a subsequent disabled call unrecorded, and records a later enabled call to the new project B destination. A JSON gptel wrapper and a legacy async wrapper also keep both events in project A while preserving caller configuration changes. The legacy callback is delivered once. Parsed actual Org ledger event blocks establish the start/finish pairs; no ledger recording mock supplies them. Other streaming/UI variants are source-test coverage rather than claimed independent runtime. The adapted real I/O recovery cases and all existing bounded probes pass at the new source freeze.

## Paired applicability and limitations

Raw private SDK method-name intent inference is applicable. Canonical names work, but direct alias/typo calls fail with `void-function`; aliases on named dispatch do not increase those raw method scores. Raw shell/write/edit safety is applicable and zero: actual wrapper denial alongside successful direct fixture writes/edits demonstrates that the raw helpers own no gate, preview or rollback. The policy wrapper and named call/async/next surfaces earn their own shared approval/review behavior, but generic rollback, leases and transactions are absent. A hand-built next descriptor can name a mutator and still passes through dispatch policy, so next safety is applicable rather than treated as read-only.

Read/search/metadata/doctor safety is n/a-as-perfect. Compile, recompile and clean safety is also n/a-as-perfect because their operations target regenerable bytecode in isolated fixtures. Offline safety follows the temporary fixture/store/loopback protection in actual source, not merely the absence of a confirmation flag. Batch n/a safety applies to declared read-only calls, preflight rejection of declared mutators and frozen original targets; it assumes honest extension effects.

Structured read/glob/grep/bash gains belong to the actual changed raw owners. Legacy streaming async methods, prose write/edit results and unchanged lookup/doctor interfaces keep their own limitations. Actual build output remains volatile: PIDs and temporary argv paths vary between controlled repeats, and ERT raw output embeds clocks/durations. Compile/recompile determinism therefore stays 500 despite machine-readable JSON; unchanged offline human timing output stays 250. No deterministic credit is inferred from an empty successful baseline compile alone. Pure fixed help/clean recipes have different applicability from subprocess reports.

The full baseline archive contains exact `git show` bytes. `probe_baseline.el` prioritized those source paths while retaining the protected source-forcing helper; its 40 records include actual baseline symbol-file locations for all scored Lisp methods. `probe_build_baseline.py` copied the actual old Makefile/helper and ran 12 commands on its own real minimal package fixture. Baseline runtime shows human diagnostic stdout, ANSI/timestamp stderr even under the requested nonterminal environment, and real nonzero compiler/ERT exits. `probe_identity.el` read source forms without executing them and confirms nine unchanged raw/lookup/doctor definitions; unchanged criteria retain the same qualitative judgment. The source identity was rerun at the final current freeze. Twenty probe/build-fixture input hashes are additionally recorded in fixture_hashes.json; copied current and baseline Makefile/helper bytes are independently checked against their source copies.

## Artifact history

Interim current evidence at `895bed7`, `3cb0cd7`, `90818f8`, `9ac13b2`, `967eb05` and `10f86bb` is explicitly suffixed and is not final current evidence. The final current runs recorded the actual SHA in `probe.target_sha`, `registry.target_sha`, `object.target_sha`, `search.target_sha`, `ledger.target_sha`, `context.target_sha`, `encoding.target_sha` and every `build-runtime.jsonl` row. The paired baseline score file is byte-identical to the prior publication. Final reruns supported the retained numerical decisions; they did not trigger an invented uplift.

`probe.initial.stdout`/`.stderr` preserve an early fixture logging error caused by serializing a symbol; this was repaired in the probe only. `baseline-build-runtime.initial.jsonl` preserves an initial copied-script executable-mode omission. The archive's offline runner was restored to its actual Git executable mode, and the two preflight records were replaced by successful actual baseline refusal runs. Neither fixture issue is a product defect. The new search fixture initially omitted its ogent-tools import, and initially used FF FE plus ASCII without NUL as a malformed BOM text case. Those initial attempts are retained with explicit suffixes. The final binary fixture uses actual UTF-16 bytes containing NUL. The malformed text correctly exposes native U+FFFD replacement characters and encoding_loss=true; its outer probe logger initially used default Emacs output coding, producing invalid byte logging. `encoding.metadata.jsonl` confirms native Unicode codepoints and `encoding.actual-tool.stdout.json` writes actual named JSON bytes with utf-8-unix and independently parses them. The final supplemental logger uses explicit utf-8-unix. These were fixture expectations/coding issues, not product defects. The initial ledger fixture accidentally bound an unused allow variable; actual policy correctly refused those SDK executions. That attempt is retained with an initial_allow_fixture suffix. The final probe uses the real ogent-tool-allow-list and exercises actual filesystem failures. The final validator was corrected to use the build helper's documented `success` status and to make owned Docker-created fixture copies readable; these corrections did not change target code or score judgments.

Scorer B changed only its own partial/evidence artifacts. No source/docs/Beads/common aggregate edits, commits or provider calls were made.


## Shared incremental revalidation at ff4e96c

Current source is `ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4`; the retained
independent numerical judgments were selected at
`a2fa8ce0533b4a508fb641f343fa55b15fd6fc60`. This update is one shared incremental
validation of those judgments, not new independent blind full readings of the
nineteen surfaces. The original raw A/B/T rows remain in the immutable
`interim_a2fa8ce_scoring.tar.gz` archive. All numerical vectors, paired baseline
bytes and earlier runtime transcripts/target markers are unchanged.

The coordinator repaired two discoveries made during the 021 refresh: selected
raw-byte filenames were silently filtered by structured glob before Unicode
validation, and Emacs 30 returned UTF-8 unibyte JSON that actual gptel could not
nest in a request. The invalidated 021 evidence retains both logger failures and
the genuine actual-gptel serializer failure in
[interim validation](../scorerA/incremental_021cca4/validation_021_pre_repair.json).
The final logger normalizes only its evidence representation; the actual
transport probe receives the product result unchanged and applies actual
gptel tool-call processing, the actual OpenAI backend result adapter and the
actual request JSON serializer. A second pending fixture call prevents FSM
advancement or network dispatch. Both runtimes now encode the original Unicode
content successfully. No provider, authentication or inference request was made.

Four new processes on real Emacs 29.1/30.2 produce **34 valid UTF-8 JSON records**:
28 behavior records and six identity guards. They cover valid/empty Unicode,
raw-byte rejection, physical raw-byte flat/recursive glob refusal, structured
read/glob repeat bytes, named calls/continuations/immediate callbacks, batch
list/vector composition, whole preflight and fail-fast, discovery/schema,
protected local doctor JSON, actual gptel tool objects and request nesting.
No full native suite or build battery was rerun by this refresh. Source guards
verify all 194 tracked production/test/build files before and after execution.
The focused citation guard fingerprints 21 files; 13 have identical Git blobs.
Actual parsed source forms identify 163 unchanged executable definitions and
six changed definitions; the private JSON-text helper is new. Thus ledger,
process, approval, raw mutation and registry evidence retain explicit unchanged
body/blob support despite localized serializer changes within larger modules.

The repairs restore the intended existing contracts within the selected bands.
They do not introduce aliases, new schemas, leases or rollback. The same anchor
interpretations and all original numbers therefore remain justified. Existing
actual Makefile/makem reports remain old executions: both owners are byte-for-byte
identical to a2fa, and 27 existing JSON reports were reparsed without new build
commands or relabeling their raw source targets. Build volatility limits remain.

[Final validation](../scorerA/incremental_final/validation.json),
[source identities](../scorerA/incremental_final/source_identities.json),
[definition identities](../scorerA/incremental_final/definition_identities.json),
[reused build reports](../scorerA/incremental_final/reused_build_reports.json) and
[preservation](../scorerA/incremental_final/preservation.json) distinguish fresh
execution from reuse. All >700 evidence remains concrete; current source hashes
and 100 citation offsets are refreshed, while 353 old runtime citations retain
their original lines and artifact hashes. A's 196 baseline artifacts and the
original B nineteen/T nine paired baseline rows remain byte-identical.


## Shared root-path revalidation at b7b966c

Current revalidated source is `b7b966c6ac5acc15d15c8ea0c70d81653072cae9`.
All original A/B nineteen, T nine and separate new-API six-per-scorer numerical
vectors remain the independent a2fa judgments. This is another shared bounded
incremental validation, not new independent blind full readings. The earlier
sections retain their own freeze identities and actual execution scope.

The ff4 source permitted an empty/excluded raw-byte directory root to appear
in native `data.path`, while JSON returned unsupported_output. The correction
validates structured glob's resolved root and reflected pattern before
enumeration, and structured search's resolved root before target classification.
The same intended unsupported_output contract now applies to both formats.
No schema, alias, approval, ledger, rollback or scoring anchor changed.

Two newly executed, source-forced Emacs 29.1/30.2 processes produce **18 valid
UTF-8 JSON records**: 14 behavior records and four identity guards. They check
actual empty and excluded raw-byte roots in explicit and configured-default
forms, native/JSON consistency, four exactly-once async callback cases per
runtime, nonempty Unicode glob/search controls, physical raw-byte descendant
refusal and reflected raw-byte glob-pattern refusal. The first attempts passed
all root errors/callbacks but used an overly strict Unicode search-path equality;
search intentionally returns directory targets with a trailing slash. Those
initial transcripts and the probe are retained with `.initial_path_expectation`
suffixes and excluded from passing conclusions. The final control checks each
owner's existing directory representation. No target source changed for this
probe correction.

All 194 tracked production/test/build files match the frozen Git source before
and after the fresh runs. The focused guard fingerprints 21 cited files;
18 are byte-identical to ff4. Actual source-form comparison checks 188 methods:
186 executable bodies/signatures are unchanged, and only
`ogent-tool-results-glob` and `ogent-tool-process--search-options` change.
Thus ff4's **34 executed records remain ff4 executions**, with their original
bytes and target markers. Unicode JSON serializers, read, batch, approval,
ledger, registry/discovery and actual-gptel wrapper bodies are unchanged.
The new valid Unicode controls and raw descendant/root/pattern tests exercise
the two changed owners. Actual-gptel request nesting is supported by the retained
successful ff4 transport records and explicit unchanged serializer/wrapper
identity; it was not independently rerun at b7.

The original a2fa runtime citations also retain their original artifact hashes
and line offsets. Current source hashes and 101 citation offsets are updated.
The unchanged Makefile/makem owners continue to justify reuse of 27 reparsed
actual old JSON build reports; no new build command or broad native battery
was run by this scorer refresh. The coordinator owns separate native validation.
A's 196 baseline artifacts and B's nineteen/T's nine baseline score rows remain
byte-identical. The original independent rows and all ff4 scoring/evidence were
archived by the coordinator before the repair. No provider or inference request
was made.

[Current validation](../scorerA/incremental_root_guard/validation.json),
[source identities](../scorerA/incremental_root_guard/source_identities.json),
[definition identities](../scorerA/incremental_root_guard/definition_identities.json),
[explicit ff4 reuse](../scorerA/incremental_root_guard/reused_ff4_evidence.json),
[artifact preservation](../scorerA/incremental_root_guard/artifact_preservation_validation.json)
and [ff4 archive](../interim_ff4e96c_archive.json) make the execution and reuse
boundaries inspectable.

## Shared incremental query validation at 5d07d80

Current source target is `5d07d807bc85a093725db24e33996b4af690ec0f`. The
original independent A/B/T numerical judgments remain at a2fa8ce. All 59
current vectors are retained: nineteen A, nineteen B, nine third readings and
six new API rows per A/B. This refresh is one shared evidence executor and
adds no independent blind full reading. The query repair restores the existing
representability contract; it does not justify changing a selected anchor.

Two successful source-forced processes on Emacs 29.1 and 30.2 emit **20 fresh
UTF-8 JSON records: sixteen behavior checks and four identity guards**. They
exercise raw pattern and raw matching/nonmatching glob filters in native/JSON
formats, sync and async delivery with exactly one callback before process
creation, valid Unicode query/filter pagination through `ogent-agent-next`,
nil optional filters and original type-error classification. The first two
process attempts created empty fixtures because the probe's `with-temp-file`
body was misplaced, then stopped at pagination. Their probe, logs, run metadata
and source guards remain under `.initial_fixture_error`; their twelve JSON
prefix records are excluded from passing conclusions. Four processes were
actually launched in this refresh, of which two succeeded.

All 194 tracked source/test/build paths match the frozen Git bytes before and
after the successful runs. Among 188 b7/current source-form comparisons, 187
bodies/signatures are identical. The only changed body is
`ogent-tool-process--search-options`; an exact module-byte comparison proves
that the two Unicode checks are the only source additions. All prior root
validation and target classification forms are preserved. Old b7 root checks
use ordinary query fields that pass the additive checks. Thus b7's **18 root
records remain b7 executions**, with all forty evidence files unchanged.
The focused guard covers 21 cited source files; nineteen whole blobs match b7.

The **34 ff4 records remain ff4 executions**, and all thirty-four evidence
files retain their bytes. Actual-gptel request nesting is supported by those
successful offline transport records on both runtimes and transitive identical
serializer/wrapper bodies from ff4 through b7 to this freeze. No transport
probe is claimed to have been rerun here. The earlier real Emacs 30 transport
defect and evidence-logger failures remain preserved in the 021 directory.

All 219 current source citations use the new source hashes and mapped offsets.
The 353 original runtime citations keep their artifact hashes, offsets and
old execution scope. A's 196 baseline artifacts and the original B/T baseline
rows remain byte-identical. Makefile and makem.sh also retain exact Git identity,
so the 27 actual old JSON build reports are reparsed and reused with disclosed
a2fa execution targets. This refresh runs no build command, broad native suite,
provider or inference request; the coordinator owns separate native validation.

[Current validation](../scorerA/incremental_query_guard/validation.json),
[source identities](../scorerA/incremental_query_guard/source_identities.json),
[definition identities](../scorerA/incremental_query_guard/definition_identities.json),
[additive query guard](../scorerA/incremental_query_guard/query_source_guard.json),
[b7 reuse](../scorerA/incremental_query_guard/reused_b7_evidence.json),
[ff4 reuse](../scorerA/incremental_query_guard/reused_ff4_evidence.json),
[artifact preservation](../scorerA/incremental_query_guard/artifact_preservation_validation.json)
and [b7 archive](../interim_b7b966c_archive.json) disclose execution and reuse.
