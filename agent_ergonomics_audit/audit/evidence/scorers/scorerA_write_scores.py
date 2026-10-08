import json
import pathlib

root = pathlib.Path('/workspace/ogent/agent_ergonomics_audit')
partial = root / 'audit/partial'
inventory = [json.loads(line) for line in (root / 'audit/surface_inventory.jsonl').read_text().splitlines()]
runtime = {row['probe']: row for line in (partial / 'scorerA_runtime.jsonl').read_text().splitlines() if (row := json.loads(line))}
make_runtime = {row['probe']: row for line in (partial / 'scorerA_make_runtime.jsonl').read_text().splitlines() if (row := json.loads(line))}
dimensions = ['agent_intuitiveness', 'agent_ergonomics', 'agent_ease_of_use',
              'output_parseability', 'error_pedagogy', 'intent_inference',
              'safety_with_recovery', 'determinism_and_reproducibility',
              'self_documentation', 'composability', 'regression_resistance']
definitions = {
 'sdk_method__tools__read-file': ([750,850,500,250,250,0,1000,750,400,750,500], 'read-valid-1', 'read-valid-2', 'read-missing',
   'One positional call reads numbered lines, with identical repeated results. Negative offset is silently accepted; negative limit silently returns empty output. Validate OFFSET >= 1 and LIMIT >= 0; offer structured line/truncation metadata. Docstring has defaults but no executable example. Safety n/a: read-only file operation.', 'test/ogent-tools-tests.el',66),
 'sdk_method__tools__glob': ([500,650,400,250,250,0,1000,700,350,750,450], 'glob-valid-1', 'glob-valid-2', 'glob-missing-root',
   'Advertised **/*.txt is not recursive: fixture root alpha.txt and nested/deep/deep.txt are omitted, only nested/near.txt returned. Define recursive semantics and sort equal-mtime ties explicitly; distinguish empty search from an invalid root. Safety n/a: read-only filesystem search.', 'test/ogent-tools-tests.el',102),
 'sdk_method__tools__grep': ([700,700,500,0,0,0,0,250,450,200,450], 'grep-valid-1', 'grep-valid-2', 'grep-invalid-regex',
   'Sync grep reports invalid-regex stderr as [1 matches], accepts negative context, and interprets a leading-hyphen pattern as flags. Quoted glob_filter executes harmless injected printf SCORERA_INJECTION. Construct argv safely or shell-quote all values, terminate option parsing, check exit status, separate stderr, expose truncation and counts as data. Safety is applicable despite read-only inventory because supplied filter demonstrably executes shell code.', 'test/ogent-tools-tests.el',666),
 'sdk_method__tools__grep-async': ([750,850,600,650,300,0,0,650,600,750,550], 'grep-async-valid-1', 'grep-async-valid-2', 'grep-async-invalid-regex',
   'Native callback events distinguish match/done/error and contain invalid regex. Shared grep command builder inherits quoted glob injection and leading-option bug; count semantics include context lines. Return stable structured match locations and validate before process launch. Safety applies because shared command construction permits execution from a filter.', 'test/ogent-tools-tests.el',1010),
 'sdk_method__tools__bash': ([750,850,450,200,0,0,0,250,400,600,500], 'bash-valid-1', 'bash-valid-2', 'bash-invalid-timeout',
   'One call executes successfully, but prose mixes stdout, stderr, exit status, timing and Emacs stderr-process lifecycle text. Invalid timeout raises raw wrong-type-argument; empty command succeeds. Raw SDK bypasses policy wrapper, so document trust boundary and add structured result/preflight validation. Prose elapsed duration is volatile.', 'test/ogent-tools-tests.el',748),
 'sdk_method__tools__bash-async': ([750,850,600,650,100,0,0,650,600,750,550], 'bash-async-valid-1', 'bash-async-valid-2', None,
   'Callback events provide stdout/stderr/done, with integer exit status. Streaming chunk boundaries and random process names limit strict reproducibility. Raw SDK executes arbitrary commands without approval; callers should use shared policy owner. Validate command, directory, timeout and make output-cap truncation explicit rather than dropping chunks silently.', 'test/ogent-tools-tests.el',974),
 'sdk_method__tools__write-file': ([750,850,250,200,0,0,0,750,250,650,450], 'write-valid', 'write-repeat', 'write-invalid-content',
   'Integer CONTENT=42 overwrites existing file with * then signals wrong-type-argument while calculating length. Validate content before mkdir/write, preserve existing bytes on rejected calls, and use safe replacement. Successful direct SDK writes overwrite immediately; policy review lives in the wrapper, not this function.', 'test/ogent-tools-tests.el',124),
 'sdk_method__tools__edit-file': ([500,700,400,250,250,0,0,500,400,500,400], 'edit-ambiguous', None, 'edit-missing-old',
   'Default schema promises unique old_string, but same same becomes changed same without rejecting ambiguity. Empty old-string plus replace-all has an unbounded zero-length count loop in source. Reject empty or ambiguous matches before changing bytes; return teaching diagnostics with occurrence count and replace-all alternative; avoid overwriting externally changed/unsaved content.', 'test/ogent-tools-tests.el',134),
 'sdk_method__registry__tool-get': ([500,850,350,750,0,0,1000,700,350,850,450], 'tool-get-valid', None, 'tool-get-typo',
   'Native gptel tool object composes with accessors. Symbol-only lookup silently returns nil for string name and typo; normalize string/symbol tool names and provide discoverable strict lookup or correction suggestions without changing deliberate missing-entry behavior. Safety n/a: registry read and registration cache refresh, no irreversible operation.', 'test/ogent-models-tests.el',507),
 'sdk_method__registry__tool-spec-get': ([750,850,400,850,0,0,1000,700,650,850,500], 'tool-spec-valid', None, 'tool-spec-string',
   'One call returns structured native plist with description, typed arguments, effects and function. No contract version, output schema or examples. Strings return nil although they name a known tool; add normalized/introspectable names. Safety n/a: read-only registry lookup.', 'test/ogent-models-tests.el',522),
 'sdk_method__registry__available-tools': ([750,850,500,750,0,0,1000,750,550,850,500], 'available-tools-1', 'available-tools-2', 'available-tools-unknown-filter',
   'Enabled tools arrive as native typed objects, repeated order stable. Misspelled enabled filter silently produces nil; distinguish disabled, empty and unknown tool names. Add JSON-safe capabilities returning sorted names, input/output contracts and effect/policy metadata. Safety n/a: registry read/cache refresh.', 'test/ogent-models-tests.el',512),
 'sdk_method__execution__wrapper': ([700,700,450,250,250,0,650,700,500,650,600], 'wrapper-stale', None, 'wrapper-arity-invalid',
   'Shared wrapper checks stale specs, policy and review, but zips args and drops extra positional values: read-file called with four values succeeds. Validate arity and supplied types before approval/ledger/mutation, provide typed failure outcomes and preserve callback-once ownership. Closure metadata is documented; whole-call examples absent.', 'test/ogent-armory-native-tests.el',110),
 'sdk_method__doctor__run': ([850,850,500,850,650,0,1000,750,600,850,750], 'doctor-run-1', 'doctor-run-2', 'doctor-crash-contained',
   'One call returns native result plists containing ID/category/status/detail/remediation; failed checks are contained and typed by status. Default skips network opt-in. Tests cover malformed results, opt-in and golden output; public API examples and output-contract version absent. Fixture repeat proves stable registry ordering, not stability of changing environment state. Safety n/a: diagnostic reads; network opt-in excluded from audit.', 'test/ogent-doctor-tests.el',76),
 'sdk_method__doctor__batch': ([750,750,650,250,650,0,1000,700,650,750,750], 'doctor-batch', None, 'doctor-crash-contained',
   'Batch SDK docstring explains shell codes 0/1/2 and requires caller kill-emacs. Prints human Org only despite structured core data. Add optional JSON output with contract version and explicit exit status metadata; keep human default and network opt-in. Safety n/a: diagnostic reads; no provider/network probes used.', 'test/ogent-doctor-tests.el',207),
 'verb__make__help': ([750,600,500,0,250,0,1000,750,500,750,0], 'help-1', 'help-2', None,
   'Human help lists examples/options and offline-test env pointer, but omits clean/recompile and EMACS override. No machine-readable target schema, failure/exit contract, or typo guidance. Add automation section and all explicit targets; preserve human help. Safety n/a: help only.', 'Makefile',134),
 'verb__make__compile': ([700,650,400,100,250,0,600,700,400,500,0], 'compile-dry', None, None,
   'Delegates to makem; make -n previews command, compilation artifacts recoverable via clean. No target-specific help/contract tests, EMACS selector absent from help; ensure selected runtime is actually propagated consistently. Baseline probe is non-mutating dry-run; prior successful compilation is not re-claimed as this scorer runtime evidence.', 'Makefile',84),
 'verb__make__recompile': ([250,600,250,0,0,0,400,700,250,0,0], 'recompile-failing-emacs', None, None,
   'Controlled fixture fake compiler exits23, make returns0 with Recompiled all .el files and no diagnostics; existing bytecode was removed first. Stop suppressing diagnostics/failures, make recompile delegate to the supported compile target with dependencies and selected Emacs, and document clean/recompile.', 'Makefile',93),
 'verb__make__clean': ([750,850,250,0,250,0,650,750,250,750,0], 'clean-1', 'clean-2', None,
   'Fixture clean removes disposable bytecode; repeated output identical. make -n gives a preview and compilation regenerates artifacts, so destructive irreversible gate is unnecessary; mutating safety still applies to generated-file scope. Help omits target and rebuild follow-up; no contract regression test.', 'Makefile',88),
 'verb__make__offline-test': ([700,750,500,100,500,0,750,500,500,650,750], 'offline-test-dry', None, None,
   'Required CI matrix covers Emacs29.1/30.2 and minimum/current gptel. Script uses loopback fixtures, bounded Emacs execution and EXIT cleanup. Dependency-directory validation occurs after starting server, generating stacktrace rather than concise preflight; validate paths/binaries before fixture setup. No provider login/inference in this audit. Full prior workflow success is source/CI evidence, not a new scorer execution.', '.github/workflows/ci.yml',74),
}

read_only_na = {'sdk_method__tools__read-file', 'sdk_method__tools__glob',
                'sdk_method__registry__tool-get', 'sdk_method__registry__tool-spec-get',
                'sdk_method__registry__available-tools', 'sdk_method__doctor__run',
                'sdk_method__doctor__batch', 'verb__make__help'}

for surface in inventory:
    sid = surface['surface_id']
    nums, probe, repeat, error_probe, notes, testfile, testline = definitions[sid]
    sdk = surface['is_sdk_surface']
    observed = runtime if sdk else make_runtime
    base = {'file': surface['source']['file'], 'line': surface['source']['line']}
    invocation = ('docker exec ogent-fixes timeout 35 emacs -Q --batch -L /work/lisp -L /work/lisp/ui -l /work/agent_ergonomics_audit/audit/partial/scorerA_probe.el; probe=' + probe) if sdk else ' '.join(observed[probe]['invocation'])
    ev = dict(base, invocation=invocation,
              transcript='audit/partial/scorerA_runtime.jsonl' if sdk else 'audit/partial/scorerA_make_runtime.jsonl',
              stdout_excerpt=observed[probe].get('result', observed[probe].get('stdout', ''))[:1400])
    evidence = {dim: dict(ev) for dim in dimensions}
    if error_probe:
        evidence['error_pedagogy'] = dict(ev, probe=error_probe, stdout_excerpt=str(observed[error_probe])[:1400])
        evidence['intent_inference'] = dict(evidence['error_pedagogy'])
    if repeat:
        evidence['determinism_and_reproducibility'] = dict(ev, repeat_probe=repeat,
             repeat_stdout_excerpt=observed[repeat].get('result', observed[repeat].get('stdout', ''))[:1400])
    elif nums[7] >= 750:
        evidence['determinism_and_reproducibility'] = dict(base, reason='Deterministic native lookup/result rendering for fixed supplied registry or fixture inputs; source has no random/wallclock fields.')
    evidence['regression_resistance'] = {'file': testfile, 'line': testline,
         'reason': 'Existing native ERT/CI coverage assessed under SDK extension; no new skill regression artifacts claimed for baseline.' if nums[10] else 'No agent contract test pins this Makefile target.'}
    if sid in read_only_na:
        evidence['safety_with_recovery'] = {'reason': 'n/a — read-only surface; no irreversible operation; optional network/provider probes excluded.'}
    if sid in {'sdk_method__doctor__run', 'sdk_method__doctor__batch'}:
        nums = list(nums)
        nums[5] = 1000
        evidence['intent_inference'] = {'reason': 'n/a — canonical invocation is a zero-argument native SDK function; CLI spelling, alias and argument-order recovery do not apply. Malformed check-result containment is assessed under error_pedagogy.'}
        notes += ' Applicability reconciliation: intent_inference n/a for this zero-argument SDK invocation; malformed checks remain error-pedagogy evidence.'
    if sid in {'sdk_method__tools__bash', 'sdk_method__tools__bash-async'}:
        nums = list(nums)
        nums[5] = 1000
        evidence['intent_inference'] = {'reason': 'n/a — these private positional SDK methods have no alternative-name or option decoder. Shell-language typo recovery is outside ogent SDK scope; invalid SDK parameters remain assessed under error_pedagogy.'}
        notes += ' Applicability reconciliation: intent_inference n/a for private positional shell methods without an SDK name decoder; shell-language typo recovery is outside scope and malformed arguments remain error-pedagogy evidence.'
    if sid in {'verb__make__clean', 'verb__make__compile', 'verb__make__recompile'}:
        nums = list(nums)
        nums[6] = 1000
        evidence['safety_with_recovery'] = {'reason': 'n/a — this target only removes or regenerates bytecode artifacts; no irreversible user-data mutation. Recompile false-success behavior remains assessed under parseability, error_pedagogy, and determinism.'}
        notes += ' Applicability reconciliation: safety_with_recovery n/a because only regenerable bytecode artifacts change; no irreversible operation requires gating.'
    if sdk:
        notes += ' SDK extension applied: one-liner native calls replace CLI mega-command criterion; native return types and docstrings evaluated; positional API has no CLI option-order semantics.'
    record = {'surface_id': sid, 'scorer_id': 'A',
              'rubric_version': 'sha256:44e7c00b3dee6be38118f1f40719d814278cb129f9aad34572e0936104b135a4',
              'scores': dict(zip(dimensions, nums)), 'weighted_score': sum(nums)/len(nums),
              'evidence': evidence, 'notes': notes}
    path = partial / f'scores_pass1_{sid}_scorerA.jsonl'
    path.write_text(json.dumps(record, ensure_ascii=False, sort_keys=True) + '\n')
    print(f'scored {sid} as A: weighted={record["weighted_score"]:.1f}; wrote {path}')
