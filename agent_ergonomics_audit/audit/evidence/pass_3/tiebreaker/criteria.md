# Independent paired tiebreaker criteria

Baseline: `b3caf9300c7336ef812ed061158f851c5a47ccf7`.
Current revalidated source freeze: `5d07d807bc85a093725db24e33996b4af690ec0f`.
Independent third numerical judgment freeze: `a2fa8ce0533b4a508fb641f343fa55b15fd6fc60`.
The independence statement below describes that original reading; the last
section records shared incremental validation of the retained judgments.
Rubric SHA-256: `44e7c00b3dee6be38118f1f40719d814278cb129f9aad34572e0936104b135a4`.

I read the skill, fresh eleven-dimension rubric, surface classes, SDK/DSL
adjustments, exemplars and counterexamples. I did not read other scorer
partials, aggregate numeric tables, or historical raw scores before choosing
these anchors. Trigger dimensions and spread thresholds were supplied by the
coordinator; no competing score values were supplied. This is an independent
third reading, not an average of the competing readings.

The two JSONL files contain nine rows each, with `scorer_id: tiebreaker` and
eleven integer scores in 50-point increments. All scores above 700 have concrete
runtime or source evidence. Scores apply the same scope and anchor interpretation
to both snapshots. Raw write/edit and Make clean scores are identical in the
paired files.

## Applicability decisions

**Execution wrapper intent applies.** The SDK guidance defines dimension 6 as
“Method aliases for common alternatives?” The inventoried API is
`ogent-tool-execution-wrapper`, which constructs a closure bound to a spec and
accepting positional values. It has no alternative method aliases. Its returned
closure does not accept a tool name, repair method spellings, or reorder bad
positional arguments. Both actual snapshots reject wrong-order arguments with
type guidance. That is useful error pedagogy, not alias inference. Calling
`ogent-tool-spec-get` before constructing a wrapper, or using the separate
`ogent-agent-call` named dispatcher, does not add aliases to the inventoried
wrapper API. This dimension is applicable and scores zero in both snapshots;
the rubric does not authorize n/a-as-perfect for a positional SDK method.

**Make recompile intent applies.** The surface class is a verb with high intent
applicability. Its mutating status does not exempt it. `make recompile` is a
named command that can be misspelled. Neither actual Makefile/runner supports
a recompile synonym. Baseline `make recompiel format=json` prints
`Invalid rule: recompiel`. Final returns an invalid-invocation report whose
message is `Unknown task 'recompiel'. Try make help` and whose next actions are
`make help` and helper capabilities. That supplies a discovery route but not
the exact recompile correction, so final receives only the 250-level partial
recovery anchor. Helpers suggesting `make compile` for `build` or `compiel`
are not aliases for the composite cleanup-and-compilation target.

**Make clean intent also applies.** It is a named mutable verb and has no
clean-specific alias or typo repair. Generic project discovery improvements
do not change the canonical cleanup API. Both paired scores remain zero.

**SDK composability follows SDK guidance.** The methodology explicitly
translates it to “SDK results compose with std types (iterators, futures,
streams)?” Baseline raw read/glob return ordinary Lisp strings and signal
catchable conditions without forcing a prompt or ANSI into returned data.
Their lack of structured output belongs to parseability. It does not make
them unusable as Lisp functions. Grep also returns a string, but its progress
timer and optional event callback add lifecycle concerns, so its composability
anchor is lower. The final optional native plists/JSON and match vectors
improve composition. These decisions are based on direct primitive calls,
not the named batching dispatcher.

**Raw mutation safety is distinct from approval safety.** Direct write
overwrites a fixture even with approval required and the tool in a deny list.
Direct edit has exact-context, multiplicity and boolean checks, but a valid
edit writes without an approval/dry-run/rollback gate. Those guards improve
error behavior; they do not transfer the execution wrapper's safety score.
The actual wrapper honors denial and routes approved edits to review without
applying the proposed content. Neither wrapper supplies leases or a rollback
contract; safety scores therefore stay below the 750 anchor.

**Generated-bytecode cleanup is bounded mutation.** Make clean removes `.elc`
under the two specified trees. It has standard GNU Make `-n` preview and
`compile` can recreate generated output, but there is no confirmation gate
or advertised rollback. Safety remains applicable with partial credit, and
never receives n/a-as-perfect. It retains human output and is documented as
excluded from JSON reporting. Improved makem reports do not confer a JSON
schema on clean.

## Runtime evidence and limits

`paired-sdk.el` preloads the installed real gptel source and loads the actual
`test/ogent-test-helper.el` by explicit source filename. The helper prepends
current Lisp; baseline paths are therefore prepended **after** the helper.
Both Emacs 30.2 and 29.1 transcripts identify the actual loaded source for
all assigned APIs and the UI executor. `source-identities.json` verifies
the seven original production paths per snapshot byte-for-byte against their
respective Git snapshots. The final refresh additionally fingerprints the
current result/process modules, actual helper, Makefile and makem. No provider,
authentication or inference API was called.

The initial Emacs 29 launch hit stale installed gptel bytecode before loading
target source. The final scorer bootstrap forces real dependency source and
both rerun transcripts exit zero. The initial Make launch hit container Git
ownership checks; final fixture calls provide a process-local safe-directory
setting and use the actual helper with real Emacs. Conclusions use the final
successful reruns.

The build fixtures copy **both** Makefile and makem from exact `git show`
snapshots, retain a real tracked Elisp source fixture, and actually compile it.
The malformed-source probe makes the compiler itself fail. No replacement
makem or Emacs executable is used. Fixture `.git` and generated `.elc` files
are removed after capturing evidence. Existing tests that use a failing shell
stand-in are cited only as limited regression coverage, not proof of actual
compiler behavior. The new checked-in report suite pins real helper behavior.

Repeated SDK calls with unchanged input/state are byte-identical, including
the structured read/search snapshots. The edit repeat probe restores initial
content before repeating; this is not a claim that edit is idempotent against
already changed content. Glob snapshots identify file metadata and search
snapshots identify observed matches; they are not stronger whole-workspace
content hashes. Build JSON contains real PIDs and generated helper paths,
which vary across runs; its determinism score does not claim byte equality.

The final wrapper JSON still passes through the interactive gptel approval
owner. The nonprompting behavior of the separate public agent SDK is not
credited to the wrapper. Likewise, helper capabilities describe helper
tasks; Make's recompile is the wrapper composite, and clean remains outside
the report contract.

## Provenance refresh at 9ac13b2

Current probes were rerun at `9ac13b23032f40eccb9a627a824be45656292056` on
actual Emacs 29.1 and 30.2. The current actual Makefile/makem fixture was copied
again from this exact Git snapshot and rerun for successful compilation,
unknown-target recovery, cleanup, JSON reports and genuine compiler failure.
The added EOF compiler probe confirms an exact source path with null line and
column when Emacs reports no position. The current source-identity record has
twelve matching current files, alongside the unchanged seven baseline files.

The intervening changes copy and compare object-table contract snapshots,
refresh cached model objects after nested schema changes, retain ownership in
EOF diagnostics, and use Unicode-aware candidate selection for ripgrep
wildcards. These repairs extend correctness and regression coverage within
the already selected scoring bands. They add neither method aliases to the
execution wrapper nor a recompile-specific typo correction, approval leases,
rollback, or a clean JSON contract. All current numerical anchors are
therefore preserved, and the baseline JSONL and baseline transcripts are
untouched. Current source citations and provenance now identify the final
freeze. Current grep transcripts use the actual GNU fallback; they do not
claim independent execution of the optional ripgrep Unicode branch.

## Provenance refresh at 967eb05

Current nine-surface SDK probes were rerun at
`967eb054e13104d05e818656a2b78f037cc0effd`, using the actual helper and real
gptel source on Emacs 29.1 and 30.2. The exact-snapshot Makefile/makem fixture
was also rerun for compilation, cleanup, malformed targets, JSON reports,
syntax failure and EOF failure. Current source hashes and score provenance
now identify this final freeze. The baseline JSONL and baseline evidence
remain untouched, and all current numeric anchors are preserved.

The new process implementation gives all directory queries the shared
candidate scope, preserves file symlink names without following directory
symlinks, and classifies selected files for NUL bytes before counting text
matches. Its classification process shares timeout and cancellation ownership
with the search. Ripgrep receives explicit sorted file arguments in bounded
batches rather than rewriting its JSON events. These repairs extend binary
and candidate-scope correctness within the current scoring bands; they do not
alter the original API applicability decisions or supply new method aliases,
approval/rollback mechanisms, or a clean JSON contract.

I additionally ran the four checked-in GNU/ripgrep binary-scope and symlink-scope
tests with the actual `/tmp/ogent-test-rg` executable on both runtimes. Each
runtime reported four expected results, zero unexpected results and no skips.
These tests cover late NUL bytes, UTF-16 BOM content, file link inclusion and
directory link exclusion through actual search executables. Their transcripts
are `current-search-scope-ogent-fixes.stderr.log` and
`current-search-scope-ogent-fixes-29.stderr.log` in this evidence directory.

## Provenance refresh at 10f86bb

Current nine-surface SDK and exact-snapshot real Makefile/makem fixture probes
were rerun at `10f86bb12a03f3122a60ba085be7289eb5277f5e`. Both actual SDK
runtimes pass, and the actual compiler success, syntax failure, EOF failure,
JSON parsing, malformed-target and cleanup observations remain supported.
The baseline nine rows remain byte-identical. All current numerical anchors
are unchanged; current source identities, wrapper contract citations and
regression-test locations now identify this freeze.

The sole intervening change preserves completed tool data and delivers one
terminal result when completion ledger I/O fails. JSON carries the typed
`ledger_write_failed` error and a recovery warning that the tool already
completed and must not be rerun to repair its ledger. Legacy results retain
their data with a visible ledger warning. Immediate asynchronous completions
return nil when there is no live process. None of these changes adds method
aliases, removes the model wrapper's interactive approval owner, or supplies
leases/rollback, so the previous applicability and score-band decisions stand.

I ran only three targeted existing ledger/immediate-return tests per runtime,
in addition to the bounded original-nine replay. Each runtime reported three
expected results, zero unexpected results and no skips. The async and sync
tests cause real ledger completion file-write failures after successful start
records, verify retained results and single terminal delivery, and exercise
the model-facing JSON wrapper. They do not substitute a ledger or tool runner.
The transcripts are `current-ledger-terminal-ogent-fixes.stderr.log` and
`current-ledger-terminal-ogent-fixes-29.stderr.log` in this evidence directory.
The earlier binary/symlink suite was not duplicated; its process source blob
is unchanged in this freeze.

## Final provenance refresh at a2fa8ce

Current nine-surface SDK probes on real Emacs 29.1 and 30.2 and the
exact-snapshot Makefile/makem compiler fixture were rerun at
`a2fa8ce0533b4a508fb641f343fa55b15fd6fc60`. Current source identities and
score provenance now identify this freeze. The baseline nine rows remain
byte-identical and all current numerical anchors are unchanged.

The intervening fix captures the enabled flag and a copied absolute ledger
path per execution. Only the start and finish records bind this captured
context; callbacks retain their ambient configuration. I ran four existing
focused tests on each runtime: asynchronous and synchronous real completion
I/O faults at the original captured ledger destination, asynchronous project
switch, and synchronous tool-context change. Each runtime reported four
expected results, zero unexpected results and no skips. Completed data and
single terminal delivery survive the I/O faults. Start and finish events stay
at the original destination after settings or project changes; callback
settings and future-call configuration remain available to their owners.
The tests use actual tools and real local ledger writes.

These repairs fit the selected scoring bands and preserve the original
applicability decisions. Current ledger transcripts are
`current-ledger-terminal-ogent-fixes.stderr.log` and
`current-ledger-terminal-ogent-fixes-29.stderr.log`; root archived the raw
previous-freeze artifacts before these current transcripts were replaced.
The bounded original-nine replay again supports compiler success and failure,
EOF file ownership, JSON reports, typo handling and cleanup. The earlier
binary/symlink suite was not duplicated; its process source blob is unchanged.


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
